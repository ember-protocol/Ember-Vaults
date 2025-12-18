#[test_only]
module ember_vaults::test_queue {
    use sui::test_scenario::{Self as test, ctx};
    use ember_vaults::queue::{Self};

    // Test addresses
    const ADMIN: address = @0x1;

    #[test]
    fun test_new_queue_is_empty() {
        let mut scenario = test::begin(ADMIN);
        
        let queue = queue::new<u64>(ctx(&mut scenario));
        
        // New queue should be empty
        assert!(queue::is_empty(&queue), 0);
        assert!(queue::len(&queue) == 0, 1);
        
        sui::test_utils::destroy(queue);
        test::end(scenario);
    }

    #[test]
    fun test_enqueue_single_element() {
        let mut scenario = test::begin(ADMIN);
        
        let mut queue = queue::new<u64>(ctx(&mut scenario));
        
        // Enqueue one element
        queue::enqueue(&mut queue, 42);
        
        // Queue should not be empty and have length 1
        assert!(!queue::is_empty(&queue), 0);
        assert!(queue::len(&queue) == 1, 1);
        
        sui::test_utils::destroy(queue);
        test::end(scenario);
    }

    #[test]
    fun test_enqueue_multiple_elements() {
        let mut scenario = test::begin(ADMIN);
        
        let mut queue = queue::new<u64>(ctx(&mut scenario));
        
        // Enqueue multiple elements
        queue::enqueue(&mut queue, 1);
        queue::enqueue(&mut queue, 2);
        queue::enqueue(&mut queue, 3);
        
        // Queue should have length 3
        assert!(!queue::is_empty(&queue), 0);
        assert!(queue::len(&queue) == 3, 1);
        
        sui::test_utils::destroy(queue);
        test::end(scenario);
    }

    #[test]
    fun test_peek_single_element() {
        let mut scenario = test::begin(ADMIN);
        
        let mut queue = queue::new<u64>(ctx(&mut scenario));
        
        // Enqueue one element
        queue::enqueue(&mut queue, 42);
        
        // Peek should return the element without removing it
        let front = queue::peek(&queue);
        assert!(*front == 42, 0);
        
        // Queue should still have the element
        assert!(!queue::is_empty(&queue), 1);
        assert!(queue::len(&queue) == 1, 2);
        
        sui::test_utils::destroy(queue);
        test::end(scenario);
    }

    #[test]
    fun test_dequeue_single_element() {
        let mut scenario = test::begin(ADMIN);
        
        let mut queue = queue::new<u64>(ctx(&mut scenario));
        
        // Enqueue one element
        queue::enqueue(&mut queue, 42);
        
        // Dequeue should return the element and remove it
        let val = queue::dequeue(&mut queue);
        assert!(val == 42, 0);
        
        // Queue should be empty
        assert!(queue::is_empty(&queue), 1);
        assert!(queue::len(&queue) == 0, 2);
        
        sui::test_utils::destroy(queue);
        test::end(scenario);
    }

    #[test]
    fun test_fifo_behavior() {
        let mut scenario = test::begin(ADMIN);
        
        let mut queue = queue::new<u64>(ctx(&mut scenario));
        
        // Enqueue elements in order: 1, 2, 3
        queue::enqueue(&mut queue, 1);
        queue::enqueue(&mut queue, 2);
        queue::enqueue(&mut queue, 3);
        
        // Dequeue should return elements in FIFO order: 1, 2, 3
        let first = queue::dequeue(&mut queue);
        assert!(first == 1, 0);
        assert!(queue::len(&queue) == 2, 1);
        
        let second = queue::dequeue(&mut queue);
        assert!(second == 2, 2);
        assert!(queue::len(&queue) == 1, 3);
        
        let third = queue::dequeue(&mut queue);
        assert!(third == 3, 4);
        assert!(queue::len(&queue) == 0, 5);
        assert!(queue::is_empty(&queue), 6);
        
        sui::test_utils::destroy(queue);
        test::end(scenario);
    }

    #[test]
    fun test_peek_multiple_elements() {
        let mut scenario = test::begin(ADMIN);
        
        let mut queue = queue::new<u64>(ctx(&mut scenario));
        
        // Enqueue elements
        queue::enqueue(&mut queue, 10);
        queue::enqueue(&mut queue, 20);
        queue::enqueue(&mut queue, 30);
        
        // Peek should always return the first element
        let front1 = queue::peek(&queue);
        assert!(*front1 == 10, 0);
        
        let front2 = queue::peek(&queue);
        assert!(*front2 == 10, 1);
        
        // Length should not change
        assert!(queue::len(&queue) == 3, 2);
        
        sui::test_utils::destroy(queue);
        test::end(scenario);
    }

    #[test]
    fun test_mixed_operations() {
        let mut scenario = test::begin(ADMIN);
        
        let mut queue = queue::new<u64>(ctx(&mut scenario));
        
        // Mix enqueue and dequeue operations
        queue::enqueue(&mut queue, 1);
        queue::enqueue(&mut queue, 2);
        
        let val1 = queue::dequeue(&mut queue);
        assert!(val1 == 1, 0);
        assert!(queue::len(&queue) == 1, 1);
        
        queue::enqueue(&mut queue, 3);
        assert!(queue::len(&queue) == 2, 2);
        
        let val2 = queue::dequeue(&mut queue);
        assert!(val2 == 2, 3);
        
        let val3 = queue::dequeue(&mut queue);
        assert!(val3 == 3, 4);
        
        assert!(queue::is_empty(&queue), 5);
        
        sui::test_utils::destroy(queue);
        test::end(scenario);
    }

    #[test]
    fun test_enqueue_after_dequeue_all() {
        let mut scenario = test::begin(ADMIN);
        
        let mut queue = queue::new<u64>(ctx(&mut scenario));
        
        // Fill queue, empty it, then fill again
        queue::enqueue(&mut queue, 1);
        queue::enqueue(&mut queue, 2);
        
        let _ = queue::dequeue(&mut queue);
        let _ = queue::dequeue(&mut queue);
        
        assert!(queue::is_empty(&queue), 0);
        
        // Enqueue again after emptying
        queue::enqueue(&mut queue, 100);
        queue::enqueue(&mut queue, 200);
        
        assert!(queue::len(&queue) == 2, 1);
        
        let val1 = queue::dequeue(&mut queue);
        assert!(val1 == 100, 2);
        
        let val2 = queue::dequeue(&mut queue);
        assert!(val2 == 200, 3);
        
        sui::test_utils::destroy(queue);
        test::end(scenario);
    }

    #[test]
    fun test_queue_with_string_type() {
        let mut scenario = test::begin(ADMIN);
        
        let mut queue = queue::new<std::string::String>(ctx(&mut scenario));
        
        let str1 = std::string::utf8(b"hello");
        let str2 = std::string::utf8(b"world");
        
        queue::enqueue(&mut queue, str1);
        queue::enqueue(&mut queue, str2);
        
        assert!(queue::len(&queue) == 2, 0);
        
        let first = queue::dequeue(&mut queue);
        assert!(first == std::string::utf8(b"hello"), 1);
        
        let second = queue::dequeue(&mut queue);
        assert!(second == std::string::utf8(b"world"), 2);
        
        sui::test_utils::destroy(queue);
        test::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = ember_vaults::queue::EEmptyQueue)]
    fun test_dequeue_empty_queue_fails() {
        let mut scenario = test::begin(ADMIN);
        
        let mut queue = queue::new<u64>(ctx(&mut scenario));
        
        // Should fail when trying to dequeue from empty queue
        let _ = queue::dequeue(&mut queue);
        
        sui::test_utils::destroy(queue);
        test::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = ember_vaults::queue::EEmptyQueue)]
    fun test_peek_empty_queue_fails() {
        let mut scenario = test::begin(ADMIN);
        
        let queue = queue::new<u64>(ctx(&mut scenario));
        
        // Should fail when trying to peek empty queue
        let _ = queue::peek(&queue);
        
        sui::test_utils::destroy(queue);
        test::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = ember_vaults::queue::EEmptyQueue)]
    fun test_dequeue_after_emptying_fails() {
        let mut scenario = test::begin(ADMIN);
        
        let mut queue = queue::new<u64>(ctx(&mut scenario));
        
        // Add and remove elements
        queue::enqueue(&mut queue, 1);
        let _ = queue::dequeue(&mut queue);
        
        // Should fail when trying to dequeue from now-empty queue
        let _ = queue::dequeue(&mut queue);
        
        sui::test_utils::destroy(queue);
        test::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = ember_vaults::queue::EEmptyQueue)]
    fun test_peek_after_emptying_fails() {
        let mut scenario = test::begin(ADMIN);
        
        let mut queue = queue::new<u64>(ctx(&mut scenario));
        
        // Add and remove elements
        queue::enqueue(&mut queue, 1);
        let _ = queue::dequeue(&mut queue);
        
        // Should fail when trying to peek now-empty queue
        let _ = queue::peek(&queue);
        
        sui::test_utils::destroy(queue);
        test::end(scenario);
    }

    #[test]
    fun test_large_queue_operations() {
        let mut scenario = test::begin(ADMIN);
        
        let mut queue = queue::new<u64>(ctx(&mut scenario));
        
        // Test with larger number of elements
        let mut i = 0;
        while (i < 100) {
            queue::enqueue(&mut queue, i);
            i = i + 1;
        };
        
        assert!(queue::len(&queue) == 100, 0);
        assert!(!queue::is_empty(&queue), 1);
        
        // Dequeue half
        i = 0;
        while (i < 50) {
            let val = queue::dequeue(&mut queue);
            assert!(val == i, 2);
            i = i + 1;
        };
        
        assert!(queue::len(&queue) == 50, 3);
        
        // Peek should show element 50
        let front = queue::peek(&queue);
        assert!(*front == 50, 4);
        
        sui::test_utils::destroy(queue);
        test::end(scenario);
    }
}