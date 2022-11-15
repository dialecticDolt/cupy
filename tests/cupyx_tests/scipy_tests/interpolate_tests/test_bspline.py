import pytest

from cupy import testing
import cupyx.scipy.interpolate  # NOQA

try:
    from scipy import interpolate  # NOQA
except ImportError:
    pass


@testing.parameterize(*testing.product({
    'extrapolate': [True, False],
    'c': [[-1, 2, 0, -1], [[-1, 2, 0, -1]] * 5]}))
@testing.with_requires("scipy")
class TestBSpline:

    def _make_random_spline(self, xp, scp, n=35, k=3):
        xp.random.seed(123)
        t = xp.sort(xp.random.random(n + k + 1))
        c = xp.random.random(n)
        return scp.interpolate.BSpline.construct_fast(t, c, k)

    @testing.numpy_cupy_allclose(scipy_name='scp', accept_error=True)
    def test_ctor(self, xp, scp):
        # knots should be an ordered 1-D array of finite real numbers
        t = [1, 1.j]
        c = [1.0]
        k = 0
        scp.interpolate.BSpline(t, c, k)

        t = [1, xp.nan]
        scp.interpolate.BSpline(t, c, k)

        t = [1, xp.inf]
        scp.interpolate.BSpline(t, c, k)

        t = [1, -1]
        scp.interpolate.BSpline(t, c, k)

        t = [[1], [1]]
        scp.interpolate.BSpline(t, c, k)

        # for n+k+1 knots and degree k need at least n coefficients
        t = [0, 1, 2]
        c = [1]
        scp.interpolate.BSpline(t, c, k)

        t = [0, 1, 2, 3, 4]
        c = [1., 1.]
        k = 2
        scp.interpolate.BSpline(t, c, k)

        # non-integer orders
        t = [0., 0., 1., 2., 3., 4.]
        c = [1., 1., 1.]
        k = "cubic"
        scp.interpolate.BSpline(t, c, k)

        t = [0., 0., 1., 2., 3., 4.]
        c = [1., 1., 1.]
        k = 2.5
        scp.interpolate.BSpline(t, c, k)

    @testing.for_all_dtypes(no_bool=True, no_complex=True)
    @testing.numpy_cupy_allclose(scipy_name='scp')
    def test_bspline(self, xp, scp, dtype):
        if xp.dtype(dtype).kind == 'u':
            pytest.skip()
        k = 2
        t = xp.arange(7, dtype=dtype)
        c = xp.asarray(self.c, dtype=dtype)
        test_xs = xp.linspace(-5, 10, 100, dtype=dtype)
        B = scp.interpolate.BSpline(t, c, k, extrapolate=self.extrapolate)
        return B(test_xs)

    @testing.numpy_cupy_allclose(scipy_name='scp')
    def test_bspline_degree_1(self, xp, scp):
        t = xp.asarray([0, 1, 2, 3, 4])
        c = xp.asarray([1, 2, 3])
        k = 1

        b = scp.interpolate.BSpline(t, c, k)
        x = xp.linspace(1, 3, 50)
        return b(x)

    @testing.for_all_dtypes(no_bool=True, no_complex=True)
    @testing.numpy_cupy_allclose(scipy_name='scp')
    def test_bspline_rndm_unity(self, xp, scp, dtype):
        if xp.dtype(dtype).kind == 'u':
            pytest.skip()

        b = self._make_random_spline(xp, scp)
        b.c = xp.ones_like(b.c)
        xx = xp.linspace(b.t[b.k], b.t[-b.k-1], 100)
        return b(xx)

    @testing.for_all_dtypes(no_bool=True, no_complex=True)
    @testing.numpy_cupy_allclose(scipy_name='scp')
    def test_vectorization(self, xp, scp, dtype):
        if xp.dtype(dtype).kind == 'u':
            pytest.skip()

        n, k = 22, 3
        t = xp.sort(xp.random.random(n))
        c = xp.random.random(size=(n, 6, 7))
        b = scp.interpolate.BSpline(t, c, k)
        tm, tp = t[k], t[-k-1]
        xx = tm + (tp - tm) * xp.random.random((3, 4, 5))
        return b(xx).shape

    @testing.for_all_dtypes(no_bool=True, no_complex=True)
    @testing.numpy_cupy_allclose(scipy_name='scp', rtol=1e-3)
    def test_bspline_len_c(self, xp, scp, dtype):
        if xp.dtype(dtype).kind == 'u':
            pytest.skip()

        # for n+k+1 knots, only first n coefs are used.
        n, k = 33, 3
        t = xp.sort(testing.shaped_random((n + k + 1,), xp))
        c = testing.shaped_random((n,), xp)

        # pad coefficients with random garbage
        c_pad = xp.r_[c, testing.shaped_random((k + 1,), xp)]

        BSpline = scp.interpolate.BSpline
        b, b_pad = BSpline(t, c, k), BSpline(t, c_pad, k)

        dt = t[-1] - t[0]

        # Locally, linspace produces relatively different values (1e-7) between
        # NumPy and CuPy during testing. Such difference results in an 1e-3
        # tolerance
        xx = xp.linspace(t[0] - dt, t[-1] + dt, 50, dtype=dtype)
        return b(xx), b_pad(xx)

    @testing.for_all_dtypes(no_bool=True, no_complex=True)
    @testing.numpy_cupy_allclose(scipy_name='scp')
    def test_basis_element(self, xp, scp, dtype):
        if xp.dtype(dtype).kind == 'u':
            pytest.skip()
        t = xp.arange(7, dtype=dtype)
        b = scp.interpolate.BSpline.basis_element(
            t, extrapolate=self.extrapolate)
        return b.tck

    @testing.for_all_dtypes(no_bool=True, no_complex=True)
    @testing.numpy_cupy_allclose(scipy_name='scp')
    @testing.with_requires('scipy>=1.8.0')
    def test_design_matrix(self, xp, scp, dtype):
        if xp.dtype(dtype).kind == 'u':
            pytest.skip()

        t = xp.arange(-1, 7, dtype=dtype)
        x = xp.arange(1, 5, dtype=dtype)
        k = 2

        mat = scp.interpolate.BSpline.design_matrix(x, t, k)
        return mat.todense()

    @testing.for_all_dtypes(no_bool=True, no_complex=True)
    @testing.numpy_cupy_allclose(scipy_name='scp')
    def test_derivative(self, xp, scp, dtype):
        if xp.dtype(dtype).kind == 'u':
            pytest.skip()

        k = 2
        t = xp.arange(7, dtype=dtype)
        c = xp.asarray(self.c, dtype=dtype)

        b = scp.interpolate.BSpline(t, c, k, extrapolate=self.extrapolate)
        return b.derivative().tck

    @testing.for_all_dtypes(no_bool=True, no_complex=True)
    @testing.numpy_cupy_allclose(scipy_name='scp')
    def test_antiderivative(self, xp, scp, dtype):
        if xp.dtype(dtype).kind == 'u':
            pytest.skip()

        k = 2
        t = xp.arange(7, dtype=dtype)
        c = xp.asarray(self.c, dtype=dtype)

        b = scp.interpolate.BSpline(t, c, k, extrapolate=self.extrapolate)
        return b.antiderivative().tck

    @testing.for_all_dtypes(no_bool=True, no_complex=True)
    @testing.numpy_cupy_allclose(scipy_name='scp')
    def test_integrate(self, xp, scp, dtype):
        if xp.dtype(dtype).kind == 'u':
            pytest.skip()

        k = 2
        t = xp.arange(7, dtype=dtype)
        c = xp.asarray(self.c, dtype=dtype)

        b = scp.interpolate.BSpline(t, c, k, extrapolate=self.extrapolate)
        return xp.asarray(b.integrate(0, 5))
