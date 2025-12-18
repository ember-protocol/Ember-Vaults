/*
  Copyright (c) 2025 Ember Protocol Inc.
  Proprietary Smart Contract License – All Rights Reserved.

  This source code is provided for transparency and verification only.
  Use, modification, reproduction, or redeployment of this code 
  requires prior written permission from the Ember Protocol Inc.
*/

module ember_vaults::queue {
    // === Imports ===
    use sui::table::{Self, Table};

    // === Errors ===
    const EEmptyQueue: u64 = 4000;

    // === Structs ===

    /// FIFO Queue
    /// 
    /// Parameters:
    /// - id: The unique identifier for the queue.
    /// - table: The table to store the queue elements.
    /// - head: The index of the first element in the queue.
    /// - tail: The index of the last element in the queue.
    public struct Queue<phantom T: store> has key, store {
        id: UID,
        table: Table<u64, T>,
        head: u64,
        tail: u64,
    }

    // === Public Functions ===

    /// Create a new empty queue
    /// 
    /// Parameters:
    /// - ctx: The mutable transaction context.
    /// 
    /// Returns:
    /// - A new empty queue.
    public fun new<T: store>(ctx: &mut TxContext): Queue<T> {
        Queue {
            id: object::new(ctx),
            table: table::new(ctx),
            head: 0,
            tail: 0,
        }
    }

    /// Enqueue a value at the tail
    /// 
    /// Parameters:
    /// - q: The mutable reference to the queue.
    /// - val: The value to enqueue.
    public fun enqueue<T: store>(q: &mut Queue<T>, val: T) {
        table::add(&mut q.table, q.tail, val);
        q.tail = q.tail + 1;
    }

    /// Dequeue a value from the head (FIFO)
    /// 
    /// Parameters:
    /// - q: The mutable reference to the queue.
    /// 
    /// Returns:
    /// - The dequeued value.
    public fun dequeue<T: store>(q: &mut Queue<T>): T {
        assert!(q.head < q.tail, EEmptyQueue); // queue must not be empty
        let val = table::remove(&mut q.table, q.head);
        q.head = q.head + 1;

        // reset queue's head and tail if the queue is empty
        if(is_empty(q)){
            q.head = 0;
            q.tail = 0;
        };

        val
    }

    /// Peek the front item without removing
    /// 
    /// Parameters:
    /// - q: The queue to peek.
    /// 
    /// Returns:
    /// - A reference to the front item.
    public fun peek<T: store>(q: &Queue<T>): &T {
        assert!(q.head < q.tail, EEmptyQueue);
        table::borrow(&q.table, q.head)
    }

    /// Check if queue is empty
    /// 
    /// Parameters:
    /// - q: The queue to check.
    /// 
    /// Returns:
    /// - True if the queue is empty, false otherwise.
    public fun is_empty<T: store>(q: &Queue<T>): bool {
        q.head == q.tail
    }

    /// Return current length of the queue
    /// 
    /// Parameters:
    /// - q: The queue to get the length of.
    /// 
    /// Returns:
    /// - The current length of the queue.
    public fun len<T: store>(q: &Queue<T>): u64 {
        q.tail - q.head
    }
}
