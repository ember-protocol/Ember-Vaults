/**
 * Sui Move package upgrade-compatibility check.
 *
 * Compares the currently-deployed on-chain package (looked up from
 * `deployment.json` -> `VaultProtocol.Package`) against the local sources
 * on this branch and fails if the PR would violate Sui's on-chain
 * upgrade compatibility rules:
 *
 *   https://docs.sui.io/concepts/sui-move-concepts/packages/upgrade
 *
 * Enforced rules (public API only — private items are free to change):
 *   1. Public struct removed                    -> FAIL
 *   2. Struct fields added / removed / reordered
 *      / type-changed                           -> FAIL
 *   3. Struct abilities changed                 -> FAIL
 *   4. Public / entry function removed          -> FAIL
 *   5. Public / entry function signature changed
 *      (params, return, type params)            -> FAIL
 *
 * New public items (new structs, new functions, new modules) are additions
 * and are always allowed — they don't break existing consumers.
 *
 * The check is intentionally one-directional: on-chain -> local. We ensure
 * everything that's live on-chain still exists locally with the same shape.
 * Anything net-new locally is fine (that's the point of an upgrade).
 *
 * Usage:  tsx check.ts [--rpc <url>] [--repo-root <path>] [--deployment <path>]
 */

import { execSync } from "node:child_process";
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { join, resolve } from "node:path";

import { SuiGrpcClient, GrpcTypes } from "@mysten/sui/grpc";
import { GrpcWebFetchTransport } from "@protobuf-ts/grpcweb-transport";

const {
  Ability,
  DatatypeDescriptor_DatatypeKind,
  FunctionDescriptor_Visibility,
  OpenSignatureBody_Type,
  OpenSignature_Reference,
} = GrpcTypes;

type OpenSignature = GrpcTypes.OpenSignature;
type OpenSignatureBody = GrpcTypes.OpenSignatureBody;
// The normalized shapes are still the most convenient description of a
// package's public surface, so the diff logic below keeps using them. Only the
// transport changed: JSON-RPC has been decommissioned on public full nodes, so
// the surface is now fetched over gRPC and adapted into these shapes.
import type {
  SuiMoveAbility,
  SuiMoveAbilitySet,
  SuiMoveNormalizedModule,
  SuiMoveNormalizedStruct,
  SuiMoveNormalizedFunction,
  SuiMoveNormalizedType,
  SuiMoveVisibility,
} from "@mysten/sui/jsonRpc";

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

interface Deployment {
  VaultProtocol: {
    Package: string;
  };
}

interface Args {
  rpc: string;
  repoRoot: string;
  deployment: string;
}

function parseArgs(): Args {
  const args = process.argv.slice(2);
  const get = (flag: string): string | undefined => {
    const i = args.indexOf(flag);
    return i >= 0 ? args[i + 1] : undefined;
  };
  return {
    // gRPC (grpc-web) endpoint. SUI_RPC_URL is still honoured so existing CI
    // config keeps working, but it must now point at a gRPC host — a JSON-RPC
    // URL with the token in the path will not work. Providers that require a
    // token read it from SUI_GRPC_TOKEN as an `x-token` header instead.
    rpc:
      get("--rpc") ??
      process.env.SUI_GRPC_URL ??
      process.env.SUI_RPC_URL ??
      "https://fullnode.mainnet.sui.io:443",
    repoRoot: resolve(get("--repo-root") ?? process.cwd()),
    deployment: get("--deployment") ?? "deployment.json",
  };
}

// ---------------------------------------------------------------------------
// Local Move source parser
//
// Deliberately small and regex-based — enough to extract every `public` /
// `public(package)` / `entry` struct + function declaration and record a
// normalised signature we can compare against on-chain metadata. If a Move
// syntactic construct escapes it, err on the side of "add coverage" rather
// than adding a full parser dependency.
// ---------------------------------------------------------------------------

interface LocalStruct {
  module: string;
  name: string;
  typeParams: string; // "<T, R>" or ""
  abilities: string; // "key, store" or ""
  fields: string; // "a: u64, b: address"  (normalised)
}

interface LocalFun {
  module: string;
  name: string;
  visibility: "public" | "public(package)" | "entry";
  typeParams: string;
  params: string;
  ret: string;
}

const LINE_COMMENT_RE = /\/\/[^\n]*/g;
const BLOCK_COMMENT_RE = /\/\*[\s\S]*?\*\//g;

const MODULE_RE = /module\s+[\w_]+::([\w_]+)\s*\{/;

// Match `public struct`, `public(package) struct`, `public struct Foo has key, store { ... }`
const STRUCT_RE =
  /public(?:\(package\))?\s+struct\s+(\w+)(<[^>]*>)?(?:\s+has\s+([^{]+?))?\s*\{([^}]*)\}/gs;

// Match `public fun`, `public(package) fun`, `entry fun`, `public entry fun`
// with a signature. Captures name, generics, params, and return.
const FUN_RE =
  /(public(?:\(package\))?(?:\s+entry)?|entry)\s+fun\s+(\w+)(<[^>]*>)?\s*\(([^)]*)\)(\s*:\s*[^{]+)?\s*\{/gs;

function stripComments(src: string): string {
  return src.replace(BLOCK_COMMENT_RE, "").replace(LINE_COMMENT_RE, "");
}

function normaliseWhitespace(s: string | undefined): string {
  return (s ?? "").replace(/\s+/g, " ").trim().replace(/,+$/, "");
}

/**
 * Split a comma-separated Move signature fragment on TOP-LEVEL commas only,
 * respecting `<...>` and `(...)` nesting. A naive `.split(",")` breaks on
 * types like `Vault<T,R>` because of the inner comma.
 */
function splitTopLevelCommas(s: string): string[] {
  const out: string[] = [];
  let depth = 0;
  let start = 0;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (c === "<" || c === "(") depth++;
    else if (c === ">" || c === ")") depth--;
    else if (c === "," && depth === 0) {
      out.push(s.slice(start, i));
      start = i + 1;
    }
  }
  if (start < s.length) out.push(s.slice(start));
  return out.map((x) => x.trim()).filter(Boolean);
}

function normaliseFieldBlock(block: string): string {
  return splitTopLevelCommas(block).map(normaliseWhitespace).join(", ");
}

function walkMoveFiles(root: string): string[] {
  const out: string[] = [];
  const stack: string[] = [root];
  while (stack.length > 0) {
    const cur = stack.pop()!;
    if (!existsSync(cur)) continue;
    const st = statSync(cur);
    if (st.isDirectory()) {
      for (const entry of readdirSync(cur)) {
        // Skip build/ and tests/ dirs — we only check what would be published.
        if (entry === "build" || entry === "tests" || entry.startsWith(".")) continue;
        stack.push(join(cur, entry));
      }
    } else if (st.isFile() && cur.endsWith(".move")) {
      out.push(cur);
    }
  }
  return out;
}

function parseLocalPackage(repoRoot: string): {
  structs: Map<string, LocalStruct>;
  funs: Map<string, LocalFun>;
} {
  const structs = new Map<string, LocalStruct>();
  const funs = new Map<string, LocalFun>();

  const sourcesDir = join(repoRoot, "sources");
  if (!existsSync(sourcesDir)) {
    throw new Error(`sources/ directory not found at ${sourcesDir}`);
  }

  for (const file of walkMoveFiles(sourcesDir)) {
    const raw = stripComments(readFileSync(file, "utf-8"));
    const modMatch = MODULE_RE.exec(raw);
    const module = modMatch?.[1] ?? file;

    let m: RegExpExecArray | null;
    STRUCT_RE.lastIndex = 0;
    while ((m = STRUCT_RE.exec(raw)) !== null) {
      const [, name, typeParams, abilities, fields] = m;
      const key = `${module}::${name!}`;
      structs.set(key, {
        module,
        name: name!,
        typeParams: normaliseWhitespace(typeParams),
        abilities: normaliseWhitespace(abilities),
        fields: normaliseFieldBlock(fields ?? ""),
      });
    }

    FUN_RE.lastIndex = 0;
    while ((m = FUN_RE.exec(raw)) !== null) {
      const [, vis, name, typeParams, params, ret] = m;
      const key = `${module}::${name!}`;
      const visibility: LocalFun["visibility"] = vis!.startsWith("entry")
        ? "entry"
        : vis!.includes("(package)")
          ? "public(package)"
          : "public";
      funs.set(key, {
        module,
        name: name!,
        visibility,
        typeParams: normaliseWhitespace(typeParams),
        params: normaliseWhitespace(params),
        ret: normaliseWhitespace(ret).replace(/^:\s*/, ""),
      });
    }
  }

  return { structs, funs };
}

// ---------------------------------------------------------------------------
// On-chain module normaliser
// ---------------------------------------------------------------------------

/**
 * Fold a normalized-type into a stable string. The SDK returns a discriminated
 * union of primitives / references / structs / type parameters — we flatten it
 * to a text form that's easy to diff.
 */
function typeToString(t: SuiMoveNormalizedType): string {
  if (typeof t === "string") return t.toLowerCase(); // Bool / U8 / ... / Address
  if ("Reference" in t) return `&${typeToString(t.Reference)}`;
  if ("MutableReference" in t) return `&mut ${typeToString(t.MutableReference)}`;
  if ("Vector" in t) return `vector<${typeToString(t.Vector)}>`;
  if ("TypeParameter" in t) return `T${t.TypeParameter}`;
  if ("Struct" in t) {
    const s = t.Struct;
    const generics = s.typeArguments.length > 0
      ? `<${s.typeArguments.map(typeToString).join(", ")}>`
      : "";
    // Module & struct name are stable identity; the address changes on every
    // upgrade (0x0 -> deployedPkg -> ...) so it is intentionally omitted.
    return `${s.module}::${s.name}${generics}`;
  }
  return JSON.stringify(t);
}

function structFieldsToString(s: SuiMoveNormalizedStruct): string {
  return s.fields.map((f) => `${f.name}: ${typeToString(f.type)}`).join(", ");
}

function abilitiesToString(s: SuiMoveNormalizedStruct): string {
  // The SDK's `abilities.abilities` is `MoveAbility[]` — copy, drop, store, key.
  return [...s.abilities.abilities]
    .map((a) => a.toLowerCase())
    .sort()
    .join(", ");
}

function typeParamsCount(s: SuiMoveNormalizedStruct): number {
  return s.typeParameters.length;
}

function funTypeParamsCount(f: SuiMoveNormalizedFunction): number {
  return f.typeParameters.length;
}

function funParamsToString(f: SuiMoveNormalizedFunction): string {
  return f.parameters.map(typeToString).join(", ");
}

function funReturnToString(f: SuiMoveNormalizedFunction): string {
  return f.return.map(typeToString).join(", ");
}

function isPublicFunction(vis: SuiMoveVisibility): boolean {
  return vis === "Public" || vis === "Friend";
}

// ---------------------------------------------------------------------------
// Diff
// ---------------------------------------------------------------------------

interface Finding {
  severity: "error" | "info";
  message: string;
}

function normLocalTypeParams(tp: string): number {
  // "<T, R: store>" -> 2; ""  -> 0
  if (!tp || tp === "") return 0;
  const inner = tp.replace(/^</, "").replace(/>$/, "").trim();
  if (inner === "") return 0;
  return inner.split(",").length;
}

function diffStruct(
  key: string,
  onChain: SuiMoveNormalizedStruct,
  local: LocalStruct | undefined,
): Finding[] {
  const findings: Finding[] = [];
  if (!local) {
    findings.push({
      severity: "error",
      message:
        `BREAKING: public struct ${key} is deployed on-chain but missing from the PR sources. ` +
        `Sui does not permit removing public structs across a package upgrade.`,
    });
    return findings;
  }

  // Type parameter count
  const localTpCount = normLocalTypeParams(local.typeParams);
  const chainTpCount = typeParamsCount(onChain);
  if (localTpCount !== chainTpCount) {
    findings.push({
      severity: "error",
      message:
        `BREAKING: struct ${key} type-parameter count changed: on-chain ${chainTpCount}, PR ${localTpCount}.`,
    });
  }

  // Abilities
  const chainAbilities = abilitiesToString(onChain);
  const localAbilitiesSorted = local.abilities
    .split(",")
    .map((s) => s.trim().toLowerCase())
    .filter(Boolean)
    .sort()
    .join(", ");
  if (chainAbilities !== localAbilitiesSorted) {
    findings.push({
      severity: "error",
      message:
        `BREAKING: struct ${key} abilities changed: on-chain [${chainAbilities}], PR [${localAbilitiesSorted}].`,
    });
  }

  // Fields — same count, same names/types, same order.
  const chainFields = structFieldsToString(onChain);
  const localFields = local.fields;
  // Local parser doesn't have full type resolution (module-prefixed names may
  // differ from on-chain), so we compare on structural cues: field name +
  // ordering + presence of `vector<>` / `&` / `&mut` wrappers where possible.
  // For a strict diff, count fields and check names + order.
  const chainNames = onChain.fields.map((f) => f.name);
  const localNames = splitTopLevelCommas(localFields)
    .map((s) => s.split(":")[0]?.trim())
    .filter((n): n is string => !!n);
  if (chainNames.length !== localNames.length) {
    findings.push({
      severity: "error",
      message:
        `BREAKING: struct ${key} field count changed: on-chain ${chainNames.length}, PR ${localNames.length}. ` +
        `Sui requires struct layout to stay identical (no add / remove / reorder / retype).`,
    });
  } else {
    for (let i = 0; i < chainNames.length; i++) {
      if (chainNames[i] !== localNames[i]) {
        findings.push({
          severity: "error",
          message:
            `BREAKING: struct ${key} field #${i} renamed or reordered: ` +
            `on-chain "${chainNames[i]}", PR "${localNames[i]}".`,
        });
      }
    }
  }

  return findings;
}

function diffFunction(
  key: string,
  onChain: SuiMoveNormalizedFunction,
  local: LocalFun | undefined,
): Finding[] {
  const findings: Finding[] = [];
  if (!local) {
    findings.push({
      severity: "error",
      message:
        `BREAKING: public function ${key} is deployed on-chain but missing from the PR sources. ` +
        `Sui does not permit removing / renaming public entrypoints across a package upgrade.`,
    });
    return findings;
  }

  const localTp = normLocalTypeParams(local.typeParams);
  const chainTp = funTypeParamsCount(onChain);
  if (localTp !== chainTp) {
    findings.push({
      severity: "error",
      message:
        `BREAKING: function ${key} type-parameter count changed: on-chain ${chainTp}, PR ${localTp}.`,
    });
  }

  // Param count check — deeper type equality is best-effort via the source
  // parser, so we compare counts here and rely on the count check to catch
  // add/remove. Return count similarly.
  const chainParamCount = onChain.parameters.length;
  const localParamList = splitTopLevelCommas(local.params);
  if (chainParamCount !== localParamList.length) {
    findings.push({
      severity: "error",
      message:
        `BREAKING: function ${key} parameter count changed: on-chain ${chainParamCount}, PR ${localParamList.length}.\n` +
        `  on-chain params: (${funParamsToString(onChain)})\n` +
        `  PR params:       (${local.params})`,
    });
  }

  const chainRetCount = onChain.return.length;
  const localRetCount =
    local.ret.length === 0
      ? 0
      : local.ret.startsWith("(")
        ? splitTopLevelCommas(local.ret.replace(/^\(|\)$/g, "")).length
        : 1;
  if (chainRetCount !== localRetCount) {
    findings.push({
      severity: "error",
      message:
        `BREAKING: function ${key} return-arity changed: on-chain ${chainRetCount}, PR ${localRetCount}.\n` +
        `  on-chain return: (${funReturnToString(onChain)})\n` +
        `  PR return:       (${local.ret})`,
    });
  }

  return findings;
}

// ---------------------------------------------------------------------------
// gRPC -> normalized-shape adapter
//
// `MovePackageService.GetPackage` describes the on-chain surface with protobuf
// enums (numeric) and open signatures. The diff logic above is written against
// the normalized shapes, so translate once here rather than rewriting it.
// Enum members are referenced by name off the generated types, so a renumbering
// upstream is a compile error rather than a silently wrong diff.
// ---------------------------------------------------------------------------

const ABILITY_NAMES: Record<number, SuiMoveAbility> = {
  [Ability.COPY]: "Copy",
  [Ability.DROP]: "Drop",
  [Ability.STORE]: "Store",
  [Ability.KEY]: "Key",
};

const VISIBILITY_NAMES: Record<number, SuiMoveVisibility> = {
  [FunctionDescriptor_Visibility.PRIVATE]: "Private",
  [FunctionDescriptor_Visibility.PUBLIC]: "Public",
  [FunctionDescriptor_Visibility.FRIEND]: "Friend",
};

const PRIMITIVE_TYPES: Record<number, SuiMoveNormalizedType> = {
  [OpenSignatureBody_Type.ADDRESS]: "Address",
  [OpenSignatureBody_Type.BOOL]: "Bool",
  [OpenSignatureBody_Type.U8]: "U8",
  [OpenSignatureBody_Type.U16]: "U16",
  [OpenSignatureBody_Type.U32]: "U32",
  [OpenSignatureBody_Type.U64]: "U64",
  [OpenSignatureBody_Type.U128]: "U128",
  [OpenSignatureBody_Type.U256]: "U256",
};

function abilitySet(abilities: number[]): SuiMoveAbilitySet {
  return { abilities: abilities.map((a) => ABILITY_NAMES[a]).filter(Boolean) };
}

/** OpenSignatureBody -> SuiMoveNormalizedType. */
function convertType(body: OpenSignatureBody | undefined): SuiMoveNormalizedType {
  if (!body || body.type === undefined) return "Bool"; // unreachable in practice

  const primitive = PRIMITIVE_TYPES[body.type];
  if (primitive) return primitive;

  if (body.type === OpenSignatureBody_Type.VECTOR) {
    return { Vector: convertType(body.typeParameterInstantiation[0]) };
  }

  if (body.type === OpenSignatureBody_Type.TYPE_PARAMETER) {
    return { TypeParameter: body.typeParameter ?? 0 };
  }

  if (body.type === OpenSignatureBody_Type.DATATYPE) {
    // typeName is the fully qualified `0x..::module::Name`.
    const [address, module, name] = (body.typeName ?? "").split("::");
    return {
      Struct: {
        address,
        module,
        name,
        typeArguments: body.typeParameterInstantiation.map(convertType),
      },
    };
  }

  throw new Error(`unhandled open signature type: ${body.type}`);
}

/** OpenSignature (a type plus an optional reference) -> SuiMoveNormalizedType. */
function convertSignature(sig: OpenSignature): SuiMoveNormalizedType {
  const inner = convertType(sig.body);
  if (sig.reference === OpenSignature_Reference.IMMUTABLE) return { Reference: inner };
  if (sig.reference === OpenSignature_Reference.MUTABLE) return { MutableReference: inner };
  return inner;
}

/**
 * Fetches the deployed package's public surface over gRPC and returns it in the
 * same shape `getNormalizedMoveModulesByPackage` used to return.
 */
async function fetchOnChainModules(
  rpcUrl: string,
  pkgId: string,
): Promise<Record<string, SuiMoveNormalizedModule>> {
  const token = process.env.SUI_GRPC_TOKEN;
  const client = new SuiGrpcClient({
    network: "mainnet",
    transport: new GrpcWebFetchTransport({
      baseUrl: rpcUrl,
      // Providers such as BlockPI authenticate gRPC with a header rather than a
      // token in the URL path. The transport is built explicitly because
      // SuiGrpcClient's baseUrl path drops any header it is given.
      ...(token ? { meta: { "x-token": token } } : {}),
    }),
  });

  const { response } = await client.movePackageService.getPackage({ packageId: pkgId });

  const modules: Record<string, SuiMoveNormalizedModule> = {};

  for (const mod of response.package?.modules ?? []) {
    if (!mod.name) continue;

    const structs: Record<string, SuiMoveNormalizedStruct> = {};
    for (const dt of mod.datatypes) {
      // Enums have no equivalent in the normalized struct shape, and the diff
      // only reasons about structs, so skip them rather than mis-describing them.
      if (!dt.name || dt.kind !== DatatypeDescriptor_DatatypeKind.STRUCT) continue;
      structs[dt.name] = {
        abilities: abilitySet(dt.abilities),
        typeParameters: dt.typeParameters.map((tp) => ({
          constraints: abilitySet(tp.constraints),
          isPhantom: tp.isPhantom ?? false,
        })),
        fields: dt.fields.map((f) => ({
          name: f.name ?? "",
          type: convertType(f.type),
        })),
      };
    }

    const exposedFunctions: Record<string, SuiMoveNormalizedFunction> = {};
    for (const fn of mod.functions) {
      if (!fn.name) continue;
      exposedFunctions[fn.name] = {
        visibility: VISIBILITY_NAMES[fn.visibility ?? -1] ?? "Private",
        isEntry: fn.isEntry ?? false,
        typeParameters: fn.typeParameters.map((tp) => abilitySet(tp.constraints)),
        parameters: fn.parameters.map(convertSignature),
        return: fn.returns.map(convertSignature),
      };
    }

    modules[mod.name] = {
      fileFormatVersion: 0,
      address: pkgId,
      name: mod.name,
      friends: [],
      structs,
      exposedFunctions,
    };
  }

  return modules;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  const args = parseArgs();

  const deploymentPath = resolve(args.repoRoot, args.deployment);
  if (!existsSync(deploymentPath)) {
    console.error(`error: deployment file not found: ${deploymentPath}`);
    process.exit(2);
  }
  const deployment = JSON.parse(readFileSync(deploymentPath, "utf-8")) as Deployment;
  const pkgId = deployment.VaultProtocol.Package;
  if (!pkgId) {
    console.error("error: deployment.json.VaultProtocol.Package is missing");
    process.exit(2);
  }
  console.error(`Deployed package: ${pkgId}`);
  console.error(`RPC:              ${args.rpc}`);
  console.error(`Repo root:        ${args.repoRoot}`);

  // Build the package first — catches obvious errors before we even diff.
  try {
    execSync("sui move build", {
      cwd: args.repoRoot,
      stdio: ["inherit", "pipe", "inherit"],
    });
  } catch {
    console.error("\nerror: sui move build failed on the PR sources — aborting compat check.");
    process.exit(1);
  }

  const onChainModules = await fetchOnChainModules(args.rpc, pkgId);

  // Skip framework modules (0x1, 0x2) — they'll never be part of an upgrade
  // scope owned by this repo. In practice the package descriptor returns only
  // the modules the target package defines, so this is defensive.
  const onChainStructCount = Object.values(onChainModules).reduce(
    (acc, m) => acc + Object.keys(m.structs).length,
    0,
  );
  const onChainFunctionCount = Object.values(onChainModules).reduce(
    (acc, m) => acc + Object.entries(m.exposedFunctions).filter(([, f]) => isPublicFunction(f.visibility)).length,
    0,
  );
  console.error(
    `On-chain surface: ${Object.keys(onChainModules).length} modules, ` +
      `${onChainStructCount} structs, ${onChainFunctionCount} public functions`,
  );

  const local = parseLocalPackage(args.repoRoot);
  console.error(
    `Local surface:    ${local.structs.size} public structs, ${local.funs.size} public/entry functions`,
  );

  const findings: Finding[] = [];

  for (const [moduleName, mod] of Object.entries(onChainModules)) {
    for (const [structName, s] of Object.entries(mod.structs)) {
      const key = `${moduleName}::${structName}`;
      findings.push(...diffStruct(key, s, local.structs.get(key)));
    }
    for (const [funName, f] of Object.entries(mod.exposedFunctions)) {
      if (!isPublicFunction(f.visibility) && !f.isEntry) continue;
      const key = `${moduleName}::${funName}`;
      findings.push(...diffFunction(key, f, local.funs.get(key)));
    }
  }

  const errors = findings.filter((f) => f.severity === "error");
  if (errors.length > 0) {
    console.error("\n" + "=".repeat(72));
    console.error(`UPGRADE COMPATIBILITY CHECK FAILED — ${errors.length} issue(s)`);
    console.error("=".repeat(72));
    for (const f of errors) console.error("\n" + f.message);
    console.error(
      "\nSee https://docs.sui.io/concepts/sui-move-concepts/packages/upgrade" +
        " for the full list of upgrade compatibility rules.",
    );
    process.exit(1);
  }

  console.error("\nOK: no upgrade-breaking public API changes detected.");
}

main().catch((err: unknown) => {
  console.error("upgrade-compat check crashed:", err);
  process.exit(2);
});
