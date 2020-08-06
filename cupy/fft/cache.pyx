# distutils: language = c++

from cupy.cuda cimport memory

import threading

from cupy.cuda import cufft


cdef object _thread_local = threading.local()


cdef class _Node:
    # Unfortunately cython cdef class cannot be nested, so the node class
    # has to live outside of the linked list...

    # data
    cdef readonly tuple key
    cdef readonly object plan
    cdef readonly Py_ssize_t memsize

    # link
    cdef _Node prev
    cdef _Node next

    def __init__(self, tuple key, plan=None):
        self.key = key
        self.plan = plan
        self.memsize = 0

        cdef memory.MemoryPointer ptr
        # work_area could be None for "empty" plans...
        if plan is not None and plan.work_area is not None:
            if isinstance(plan.work_area, list):
                # multi-GPU plan, add up all memory usage as we don't do
                # per-device cache (yet)
                for ptr in plan.work_area:
                    self.memsize += ptr.mem.size
            else:
                # single-GPU plan
                self.memsize = <Py_ssize_t>plan.work_area.mem.size

        self.prev = None
        self.next = None

    def __repr__(self):
        cdef str output
        cdef str plan_type
        if isinstance(self.plan, cufft.Plan1d):
            plan_type = 'Plan1d'
        elif isinstance(self.plan, cufft.PlanNd):
            plan_type = 'PlanNd'
        else:
            raise TypeError('unrecognized plan type: {}'.format(type(self.plan)))
        output = 'key: {0}, plan type: {1}, memory usage: {2}'.format(
            self.key, plan_type, self.memsize)
        return output


cdef class _LinkedList:
    # link
    cdef _Node head
    cdef _Node tail
    cdef readonly size_t count

    def __init__(self):
        """ A doubly linked list to be used as an LRU cache. """
        self.head = _Node(None, None)
        self.tail = _Node(None, None)
        self.count = 0
        self.head.next = self.tail
        self.tail.prev = self.head

    cdef void remove_node(self, _Node node):
        """ Remove the node from the linked list. """
        cdef _Node p = node.prev
        cdef _Node n = node.next
        p.next = n
        n.prev = p
        self.count -= 1

    cdef void append_node(self, _Node node):
        """ Add a node to the tail of the linked list. """
        cdef _Node t = self.tail
        cdef _Node p = t.prev
        p.next = node
        t.prev = node
        node.prev = p
        node.next = t
        self.count += 1


cdef class PlanCache:
    # total number of plans, regardless of plan type
    # -1: unlimited/ignored, cache size is restricted by "memsize"
    # 0: disable cache
    cdef Py_ssize_t size

    # current number of cached plans
    cdef Py_ssize_t curr_size

    # total amount of memory for all of the cached plans
    # -1: unlimited/ignored, cache size is restricted by "size"
    # 0: disable cache
    cdef Py_ssize_t memsize

    # current amount of memory used by cached plans
    cdef Py_ssize_t curr_memsize

    # whether the cache is enabled (True) or disabled (False)
    cdef bint is_enabled

    # key: all arguments used to construct Plan1d or PlanNd
    # value: the node that holds the plan corresponding to the key
    cdef dict cache

    # for keeping track of least recently used plans
    # lru.head: least recent used
    # lru.tail: most recent used
    cdef _LinkedList lru

    cdef inline void _reset(self):
        self.curr_size = 0
        self.curr_memsize = 0
        self.cache = {}
        self.lru = _LinkedList()

    def __init__(self, Py_ssize_t size=4, Py_ssize_t memsize=-1):
        # TODO(leofang): use stream as part of cache key?
        self._validate_size_memsize(size, memsize)
        self._set_size_memsize(size, memsize)
        self._reset()

        if hasattr(_thread_local, '_current_plan_cache'):
            import warnings
            warnings.warn('invalidating the existing thread-local '
                          'plan cache...')
        _thread_local._current_plan_cache = self

    def __getitem__(self, tuple key):
        # no-op if cache is disabled
        if not self.is_enabled:
            assert (self.size == 0 or self.memsize == 0)
            return

        cdef _Node node = self.cache.get(key)
        if node is not None:
            # hit, move the node to the end
            self.lru.remove_node(node)
            self.lru.append_node(node)
            return node.plan
        else:
            raise KeyError('plan not found for key: {}'.format(key))

    def __setitem__(self, tuple key, plan):
        cdef _Node node = _Node(key, plan)
        cdef _Node unwanted_node

        # no-op if cache is disabled
        if not self.is_enabled:
            assert (self.size == 0 or self.memsize == 0)
            return

        # First, check for the worst case: the plan is too large to fit in
        # the cache. In this case, we leave the cache intact and return early.
        if (node.memsize > self.memsize > 0):
            raise RuntimeError('cannot insert the plan -- perhaps '
                               'cache size/memsize too small?')

        # Now we ensure we have room to insert, check if the key already exists
        unwanted_node = self.cache.get(key)
        if unwanted_node is not None:
            self._remove_plan(unwanted_node)
            # self.cache will be updated later, so don't del

        # See if the plan can fit in, if not we remove least used ones
        self._eject_until_fit(
            self.size - 1 if self.size != -1 else -1,
            self.memsize - node.memsize if self.memsize != -1 else -1)

        # At this point we ensure we have room to insert
        self._add_plan(node)
        self.cache[key] = node

    cdef void _validate_size_memsize(
            self, Py_ssize_t size, Py_ssize_t memsize) except*:
        if size < -1 or memsize < -1:
            raise ValueError('invalid input')

    cdef void _set_size_memsize(self, Py_ssize_t size, Py_ssize_t memsize):
        self.size = size
        self.memsize = memsize
        self.is_enabled = (size != 0 and memsize != 0)

    cdef void _remove_plan(self, _Node node):
        """ Remove the node corresponding to the given plan from the list. """
        # update linked list
        self.lru.remove_node(node)

        # update bookkeeping
        self.curr_size -= 1
        self.curr_memsize -= node.memsize

    cdef void _add_plan(self, _Node node):
        """ Add a node corresponding to the given plan to the tail of the list. """
        # update linked list
        self.lru.append_node(node)

        # update bookkeeping
        self.curr_size += 1
        self.curr_memsize += node.memsize

    cpdef set_size(self, Py_ssize_t size):
        self._validate_size_memsize(size, self.memsize)
        self._eject_until_fit(size, self.memsize)
        self._set_size_memsize(size, self.memsize)

    cpdef Py_ssize_t get_size(self):
        return self.size

    cpdef set_memsize(self, Py_ssize_t memsize):
        self._validate_size_memsize(self.size, memsize)
        self._eject_until_fit(self.size, memsize)
        self._set_size_memsize(self.size, memsize)

    cpdef Py_ssize_t get_memsize(self):
        return self.memsize

    cpdef get(self, tuple key, default=None):
        # behaves as if calling dict.get()
        try:
            plan = self[key]
        except KeyError:
            plan = default
        else:
            if plan is None:
                plan = default
        return plan

    cdef inline void _eject_until_fit(self, Py_ssize_t size, Py_ssize_t memsize):
        cdef _Node unwanted_node
        while True:
            if (self.curr_size == 0
                or ((self.curr_size <= size or size == -1)
                    and (self.curr_memsize <= memsize or memsize == -1))):
                break
            else:
                # remove from the front to free up space
                unwanted_node = self.lru.head.next
                if unwanted_node is not self.lru.tail:
                    self._remove_plan(unwanted_node)
                    del self.cache[unwanted_node.key]

    cpdef clear(self):
        self._reset()

    def __repr__(self):
        # we also validate data when the cache information is needed
        assert len(self.cache) == int(self.lru.count) == self.curr_size
        if self.size >= 0:
            assert self.curr_size <= self.size
        if self.memsize >= 0:
            assert self.curr_memsize <= self.memsize

        cdef str output = '-------------- cuFFT plan cache --------------\n'
        output += 'cache enabled? {}\n'.format(self.is_enabled)
        output += 'current / max size: {0} / {1} (counts)\n'.format(
            self.curr_size,
            '(unlimited)' if self.size == -1 else self.size)
        output += 'current / max memsize: {0} / {1} (bytes)\n'.format(
            self.curr_memsize,
            '(unlimited)' if self.memsize == -1 else self.memsize)
        output += '\ncached plans (least used first):\n'

        # TODO(leofang): maybe traverse from the end?
        cdef _Node node = self.lru.head
        cdef size_t count = 0
        while node.next is not self.lru.tail:
            node = node.next
            output += str(node) + '\n'
            assert self.cache[node.key] is node
            count += 1
        assert count == self.lru.count
        return output[:-1]

    cpdef show_info(self):
        print(self)


# TODO(leofang): mark this API experimental until scipy/scipy#12512 is merged and released
cpdef Py_ssize_t get_plan_cache_size(size):
    if not hasattr(_thread_local, '_current_plan_cache'):
        raise RuntimeError('cache not found')
    cdef PlanCache cache = _thread_local._current_plan_cache
    return cache.get_size()


# TODO(leofang): mark this API experimental until scipy/scipy#12512 is merged and released
cpdef set_plan_cache_size(size):
    if not hasattr(_thread_local, '_current_plan_cache'):
        raise RuntimeError('cache not found')
    cdef PlanCache cache = _thread_local._current_plan_cache
    cache.set_size(size)


# TODO(leofang): mark this API experimental until scipy/scipy#12512 is merged and released
cpdef Py_ssize_t get_plan_cache_max_memsize(size):
    if not hasattr(_thread_local, '_current_plan_cache'):
        raise RuntimeError('cache not found')
    cdef PlanCache cache = _thread_local._current_plan_cache
    return cache.get_memsize()


# TODO(leofang): mark this API experimental until scipy/scipy#12512 is merged and released
cpdef set_plan_cache_max_memsize(size):
    if not hasattr(_thread_local, '_current_plan_cache'):
        raise RuntimeError('cache not found')
    cdef PlanCache cache = _thread_local._current_plan_cache
    cache.set_memsize(size)


# TODO(leofang): mark this API experimental until scipy/scipy#12512 is merged and released
cpdef clear_plan_cache():
    if not hasattr(_thread_local, '_current_plan_cache'):
        raise RuntimeError('cache not found')
    cdef PlanCache cache = _thread_local._current_plan_cache
    cache.clear()


# enable cache by default
# TODO(leofang): expose this handle to cupy.fft or cupy.fft.config,
# since it's expected to work as a singleton?
plan_cache = PlanCache(size=16)
