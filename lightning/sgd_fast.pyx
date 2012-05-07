# encoding: utf-8
# cython: cdivision=True
# cython: boundscheck=False
# cython: wraparound=False
#
# Author: Mathieu Blondel
#         Peter Prettenhofer (loss functions)
# License: BSD

import numpy as np
cimport numpy as np

cdef extern from "math.h":
    cdef extern double exp(double x)
    cdef extern double log(double x)
    cdef extern double sqrt(double x)
    cdef extern double pow(double x, double y)

cdef extern from "float.h":
   double DBL_MAX

cdef class LossFunction:

    cpdef double get_update(self, double p, double y):
        raise NotImplementedError()


cdef class ModifiedHuber(LossFunction):

    cpdef double get_update(self, double p, double y):
        cdef double z = p * y
        if z >= 1.0:
            return 0.0
        elif z >= -1.0:
            return 2.0 * (1.0 - z) * y
        else:
            return 4.0 * y


cdef class Hinge(LossFunction):

    cdef double threshold

    def __init__(self, double threshold=1.0):
        self.threshold = threshold

    cpdef double get_update(self, double p, double y):
        cdef double z = p * y
        if z <= self.threshold:
            return y
        return 0.0


cdef class Log(LossFunction):

    cpdef double get_update(self, double p, double y):
        cdef double z = p * y
        # approximately equal and saves the computation of the log
        if z > 18.0:
            return exp(-z) * y
        if z < -18.0:
            return y
        return y / (exp(z) + 1.0)


cdef class SparseLog(LossFunction):

    cdef double threshold, gamma

    def __init__(self, double threshold=0.99):
        self.threshold = threshold
        self.gamma = -log((1 - threshold)/threshold)

    cpdef double get_update(self, double p, double y):
        cdef double z = p * y
        if z > self.threshold:
            return 0
        return self.gamma * y / (exp(self.gamma * z) + 1.0)

    cpdef double get_gamma(self):
        return self.gamma


cdef class SquaredLoss(LossFunction):

    cpdef double get_update(self, double p, double y):
        return y - p


cdef class Huber(LossFunction):

    cdef double c

    def __init__(self, double c):
        self.c = c

    cpdef double get_update(self, double p, double y):
        cdef double r = p - y
        cdef double abs_r = abs(r)
        if abs_r <= self.c:
            return -r
        elif r > 0.0:
            return -self.c
        else:
            return self.c


cdef class EpsilonInsensitive(LossFunction):

    cdef double epsilon

    def __init__(self, double epsilon):
        self.epsilon = epsilon

    cpdef double get_update(self, double p, double y):
        if y - p > self.epsilon:
            return 1
        elif p - y > self.epsilon:
            return -1
        else:
            return 0


cdef double _dot(np.ndarray[double, ndim=2, mode='c'] W,
                 int k,
                 np.ndarray[double, ndim=2, mode='c'] X,
                 int i):
    cdef Py_ssize_t n_features = X.shape[1]
    cdef int j

    cdef double pred = 0.0

    for j in xrange(n_features):
        pred += X[i, j] * W[k, j]

    return pred


cdef void _add(np.ndarray[double, ndim=2, mode='c'] W,
               int k,
               np.ndarray[double, ndim=2, mode='c'] X,
               int i,
               double scale):
    cdef Py_ssize_t n_features = X.shape[1]
    cdef int j

    for j in xrange(n_features):
        W[k, j] += X[i, j] * scale

cdef double _get_eta(int learning_rate, double lmbda,
                     double eta0, double power_t, long t):
    cdef double eta = eta0
    if learning_rate == 2: # PEGASOS
        eta = 1.0 / (lmbda * t)
    elif learning_rate == 3: # INVERSE SCALING
        eta = eta0 / pow(t, power_t)
    return eta

def _binary_linear_sgd(self,
                       np.ndarray[double, ndim=2, mode='c'] W,
                       np.ndarray[double, ndim=1] intercepts,
                       int k,
                       np.ndarray[double, ndim=2, mode='c'] X,
                       np.ndarray[double, ndim=1] y,
                       LossFunction loss,
                       double lmbda,
                       int learning_rate,
                       double eta0,
                       double power_t,
                       int fit_intercept,
                       double intercept_decay,
                       int max_iter,
                       random_state,
                       int verbose):

    cdef Py_ssize_t n_samples = X.shape[0]
    cdef Py_ssize_t n_features = X.shape[1]

    cdef np.ndarray[int, ndim=1, mode='c'] indices
    indices = np.arange(n_samples, dtype=np.int32)

    cdef int it, i
    cdef long t = 1
    cdef double update, pred, eta
    cdef double w_scale = 1.0
    cdef double intercept = 0.0

    for it in xrange(max_iter):
        random_state.shuffle(indices)

        for i in xrange(n_samples):
            pred = _dot(W, k, X, i)
            pred *= w_scale
            pred += intercepts[k]

            eta = _get_eta(learning_rate, lmbda, eta0, power_t, t)
            update = loss.get_update(pred, y[i])

            if update != 0:
                update *= eta

                _add(W, k, X, i, update / w_scale)

                if fit_intercept:
                    intercepts[k] += update * intercept_decay

            w_scale *= (1 - lmbda * eta)

            if w_scale < 1e-9:
                W[k] *= w_scale
                w_scale = 1.0

            t += 1

    if w_scale != 1.0:
        W[k] *= w_scale


cdef int _predict_multiclass(np.ndarray[double, ndim=2, mode='c'] W,
                             np.ndarray[double, ndim=1] w_scales,
                             np.ndarray[double, ndim=1] intercepts,
                             np.ndarray[double, ndim=2, mode='c'] X,
                             int i):
    cdef Py_ssize_t n_features = X.shape[1]
    cdef Py_ssize_t n_vectors = W.shape[0]
    cdef int j, l

    cdef double pred
    cdef double best = -DBL_MAX
    cdef int selected = 0

    for l in xrange(n_vectors):
        pred = 0

        for j in xrange(n_features):
            pred += X[i, j] * W[l, j]

        pred *= w_scales[l]
        pred += intercepts[l]

        # pred += loss(y_true, y_pred)

        if pred > best:
            best = pred
            selected = l

    return selected

def _multiclass_hinge_linear_sgd(self,
                                 np.ndarray[double, ndim=2, mode='c'] W,
                                 np.ndarray[double, ndim=1] intercepts,
                                 np.ndarray[double, ndim=2, mode='c'] X,
                                 np.ndarray[int, ndim=1] y,
                                 double lmbda,
                                 int learning_rate,
                                 double eta0,
                                 double power_t,
                                 int fit_intercept,
                                 double intercept_decay,
                                 int max_iter,
                                 random_state,
                                 int verbose):

    cdef Py_ssize_t n_samples = X.shape[0]
    cdef Py_ssize_t n_features = X.shape[1]
    cdef Py_ssize_t n_vectors = W.shape[0]

    cdef np.ndarray[int, ndim=1, mode='c'] indices
    indices = np.arange(n_samples, dtype=np.int32)

    cdef int it, i, l
    cdef long t = 1
    cdef double update, pred, eta, scale
    cdef double intercept = 0.0

    cdef np.ndarray[double, ndim=1, mode='c'] w_scales
    w_scales = np.ones(n_vectors, dtype=np.float64)

    for it in xrange(max_iter):
        random_state.shuffle(indices)

        for i in xrange(n_samples):
            eta = _get_eta(learning_rate, lmbda, eta0, power_t, t)
            k = _predict_multiclass(W, w_scales, intercepts, X, i)

            if k != y[i]:
                _add(W, k, X, i, -eta / w_scales[k])
                _add(W, y[i], X, i, eta / w_scales[y[i]])

                if fit_intercept:
                    scale = eta * intercept_decay
                    intercepts[k] -= scale
                    intercepts[y[i]] += scale

            scale = (1 - lmbda * eta)
            for l in xrange(n_vectors):
                w_scales[l] *= scale

                if w_scales[l] < 1e-9:
                    W[l] *= w_scales[l]
                    w_scales[l] = 1.0

            t += 1

    for l in xrange(n_vectors):
        if w_scales[l] != 1.0:
            W[l] *= w_scales[l]

