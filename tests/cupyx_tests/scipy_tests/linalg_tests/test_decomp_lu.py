import unittest

import numpy
try:
    import scipy.linalg

    scipy_available = True
except ImportError:
    scipy_available = False

import cupy
from cupy import cuda
from cupy import testing
import cupyx.scipy.linalg


@unittest.skipUnless(
    cuda.cusolver_enabled, 'Only cusolver in CUDA 8.0 is supported')
@unittest.skipUnless(scipy_available, 'requires scipy')
@testing.gpu
@testing.parameterize(*testing.product({
    'shape': [(1, 1), (2, 2), (3, 3), (5, 5)],
}))
@testing.fix_random()
class TestLUFactor(unittest.TestCase):

    @testing.for_float_dtypes(no_float16=True)
    def check_x(self, array, dtype):
        a_cpu = numpy.asarray(array, dtype=dtype)
        a_gpu = cupy.asarray(array, dtype=dtype)
        result_cpu = scipy.linalg.lu_factor(a_cpu)
        result_gpu = cupyx.scipy.linalg.lu_factor(a_gpu)
        self.assertEqual(len(result_cpu), len(result_gpu))
        self.assertEqual(result_cpu[0].dtype, result_gpu[0].dtype)
        self.assertEqual(result_cpu[1].dtype, result_gpu[1].dtype)
        cupy.testing.assert_allclose(result_cpu[0], result_gpu[0], atol=1e-5)
        cupy.testing.assert_array_equal(result_cpu[1], result_gpu[1])

    def test_lu_factor(self):
        self.check_x(numpy.random.randn(*self.shape))


@unittest.skipUnless(
    cuda.cusolver_enabled, 'Only cusolver in CUDA 8.0 is supported')
@unittest.skipUnless(scipy_available, 'requires scipy')
@testing.gpu
@testing.parameterize(*testing.product({
    'trans': [0, 1, 2],
    'shapes': [((4, 4), (4,)), ((5, 5), (5, 2))],
}))
@testing.fix_random()
class TestLUSolve(unittest.TestCase):

    @testing.for_float_dtypes(no_float16=True)
    @testing.numpy_cupy_allclose(atol=1e-5, scipy_name='scp')
    def test_solve(self, xp, scp, dtype):
        a_shape, b_shape = self.shapes
        A = testing.shaped_random(a_shape, xp, dtype=dtype)
        b = testing.shaped_random(b_shape, xp, dtype=dtype)
        lu = scp.linalg.lu_factor(A)
        return scp.linalg.lu_solve(lu, b, trans=self.trans)
