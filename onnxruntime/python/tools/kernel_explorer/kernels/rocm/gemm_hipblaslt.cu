// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#include <pybind11/stl.h>

#include <string>
#include <vector>

#ifdef USE_HIPBLASLT
#include "core/providers/rocm/tunable/gemm_hipblaslt.h"
#endif

#include "core/providers/rocm/rocm_common.h"
#include "core/providers/rocm/tunable/gemm_common.h"
#include "python/tools/kernel_explorer/device_array.h"
#include "python/tools/kernel_explorer/kernel_explorer_interface.h"

using namespace onnxruntime::rocm::tunable::blas;

namespace py = pybind11;

namespace onnxruntime {

#ifdef USE_HIPBLASLT

using namespace rocm::tunable::blas::internal;

template <typename T, typename ALayout, typename BLayout>
class GemmHipBlasLt : public IKernelExplorer {
 public:
  GemmHipBlasLt(BlasOp opa, BlasOp opb,
                int64_t m, int64_t n, int64_t k,
                double alpha,
                DeviceArray& a, int64_t lda,
                DeviceArray& b, int64_t ldb,
                double beta,
                DeviceArray& c, int64_t ldc)
      : params_{} {
    params_.tuning_ctx = TuningContext();
    params_.stream = Stream();
    // rocblas handle is not used for hipBLASLt
    params_.handle = nullptr;
    params_.opa = opa;
    params_.opb = opb;
    params_.m = m;
    params_.n = n;
    params_.k = k;
    params_.alpha = alpha;
    params_.a = static_cast<T*>(a.ptr());
    params_.lda = lda;
    params_.b = static_cast<T*>(b.ptr());
    params_.ldb = ldb;
    params_.beta = beta;
    params_.c = static_cast<T*>(c.ptr());
    params_.ldc = ldc;

    for (auto&& [type_string, op] : GetHipBlasLtGemmTypeStringAndOps<T, ALayout, BLayout>()) {
      type_strings_.emplace_back(std::move(type_string));
      ops_.emplace_back(std::move(op));
    }
    ORT_ENFORCE(!ops_.empty());
  }

  void Run() override {
    ORT_THROW_IF_ERROR(ops_[selected_op_](&params_));
  }

  std::vector<std::string> ListOps() const {
    return type_strings_;
  }

  bool SelectOp(const std::string& name) {
    for (size_t i = 0; i < ops_.size(); i++) {
      if (type_strings_[i] == name) {
        selected_op_ = i;
        Status status = ops_[i](&params_);
        return status.IsOK();
      }
    }

    ORT_THROW("Cannot find implementation ", name);
  }

 private:
  using ParamsT = GemmParams<T>;
  using OpT = Op<ParamsT>;
  ParamsT params_;
  std::vector<OpT> ops_;
  std::vector<std::string> type_strings_;
  size_t selected_op_{};
};

template <typename T, typename ALayout, typename BLayout>
class StridedBatchedGemmHipBlasLt : public IKernelExplorer {
 public:
  StridedBatchedGemmHipBlasLt(
      BlasOp opa, BlasOp opb,
      int64_t m, int64_t n, int64_t k,
      double alpha,
      DeviceArray& a, int64_t lda, int64_t stride_a,
      DeviceArray& b, int64_t ldb, int64_t stride_b,
      double beta,
      DeviceArray& c, int64_t ldc, int64_t stride_c,
      int64_t batch)
      : params_{} {
    params_.tuning_ctx = TuningContext();
    params_.stream = Stream();
    // rocblas handle is not used for hipBLASLt
    params_.handle = nullptr;
    params_.opa = opa;
    params_.opb = opb;
    params_.m = m;
    params_.n = n;
    params_.k = k;
    params_.alpha = alpha;
    params_.a = static_cast<T*>(a.ptr());
    params_.lda = lda;
    params_.stride_a = stride_a;
    params_.b = static_cast<T*>(b.ptr());
    params_.ldb = ldb;
    params_.stride_b = stride_b;
    params_.beta = beta;
    params_.c = static_cast<T*>(c.ptr());
    params_.ldc = ldc;
    params_.stride_c = stride_c;
    params_.batch = batch;

    for (auto&& [type_string, op] : GetHipBlasLtStridedBatchedGemmTypeStringAndOps<T, ALayout, BLayout>()) {
      type_strings_.emplace_back(std::move(type_string));
      ops_.emplace_back(std::move(op));
    }
    ORT_ENFORCE(!ops_.empty());
  }

  void Run() override {
    ORT_THROW_IF_ERROR(ops_[selected_op_](&params_));
  }

  std::vector<std::string> ListOps() const {
    return type_strings_;
  }

  bool SelectOp(const std::string& name) {
    for (size_t i = 0; i < ops_.size(); i++) {
      if (type_strings_[i] == name) {
        selected_op_ = i;
        Status status = ops_[i](&params_);
        return status.IsOK();
      }
    }

    ORT_THROW("Cannot find implementation ", name);
  }

 private:
  using ParamsT = StridedBatchedGemmParams<T>;
  using OpT = Op<ParamsT>;
  ParamsT params_;
  std::vector<OpT> ops_;
  std::vector<std::string> type_strings_;
  size_t selected_op_{};
};

#define REGISTER_OP_COMMON(type, dtype, alayout, blayout, layout_string)           \
  py::class_<type<dtype, alayout, blayout>>(m, #type "_" #dtype "_" layout_string) \
      .def("SetRepeats", &type<dtype, alayout, blayout>::SetRepeats)               \
      .def("Profile", &type<dtype, alayout, blayout>::Profile)                     \
      .def("Run", &type<dtype, alayout, blayout>::Run)                             \
      .def("ListOps", &type<dtype, alayout, blayout>::ListOps)                     \
      .def("SelectOp", &type<dtype, alayout, blayout>::SelectOp)

#define REGISTER_GEMM_HIPBLASLT(dtype, alayout, blayout, layout_string)     \
  REGISTER_OP_COMMON(GemmHipBlasLt, dtype, alayout, blayout, layout_string) \
      .def(py::init<BlasOp, BlasOp, int64_t, int64_t, int64_t,              \
                    double,                                                 \
                    DeviceArray&, int64_t,                                  \
                    DeviceArray&, int64_t,                                  \
                    double,                                                 \
                    DeviceArray&, int64_t>());

#define REGISTER_GEMM_HIPBLASLT_FOR_ALL_TRANSAB(dtype) \
  REGISTER_GEMM_HIPBLASLT(dtype, Row, Row, "NN");      \
  REGISTER_GEMM_HIPBLASLT(dtype, Row, Col, "NT");      \
  REGISTER_GEMM_HIPBLASLT(dtype, Col, Row, "TN");      \
  REGISTER_GEMM_HIPBLASLT(dtype, Col, Col, "TT");

#define REGISTER_STRIDEDBATCHEDGEMM_HIPBLASLT(dtype, alayout, blayout, layout_string)     \
  REGISTER_OP_COMMON(StridedBatchedGemmHipBlasLt, dtype, alayout, blayout, layout_string) \
      .def(py::init<BlasOp, BlasOp, int64_t, int64_t, int64_t,                            \
                    double,                                                               \
                    DeviceArray&, int64_t, int64_t,                                       \
                    DeviceArray&, int64_t, int64_t,                                       \
                    double,                                                               \
                    DeviceArray&, int64_t, int64_t,                                       \
                    int64_t>());

#define REGISTER_STRIDEDBATCHEDGEMM_HIPBLASLT_FOR_ALL_TRANSAB(dtype) \
  REGISTER_STRIDEDBATCHEDGEMM_HIPBLASLT(dtype, Row, Row, "NN");      \
  REGISTER_STRIDEDBATCHEDGEMM_HIPBLASLT(dtype, Row, Col, "NT");      \
  REGISTER_STRIDEDBATCHEDGEMM_HIPBLASLT(dtype, Col, Row, "TN");      \
  REGISTER_STRIDEDBATCHEDGEMM_HIPBLASLT(dtype, Col, Col, "TT");

KE_REGISTER(m) {
  REGISTER_GEMM_HIPBLASLT_FOR_ALL_TRANSAB(float);
  REGISTER_GEMM_HIPBLASLT_FOR_ALL_TRANSAB(half);

  REGISTER_STRIDEDBATCHEDGEMM_HIPBLASLT_FOR_ALL_TRANSAB(float);
  REGISTER_STRIDEDBATCHEDGEMM_HIPBLASLT_FOR_ALL_TRANSAB(half);
}
#endif  // USE_HIPBLASLT

}  // namespace onnxruntime
