# Copyright 2021 The TensorFlow Authors. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ==============================================================================
"""Helpers for mini-benchmark build rules."""

load(
    "//tensorflow:tensorflow.bzl",
    "clean_dep",
)
load("//tensorflow/lite/core/shims:cc_library_with_tflite.bzl", "add_suffix")
load("//tensorflow/lite/experimental/acceleration/mini_benchmark:special_rules.bzl", "libjpeg_handle_deps")

def embedded_binary(name, binary, array_variable_name, testonly = False, exec_properties = None):
    """Create a cc_library that embeds a binary as constant data.

    Args:
        name: name for the generated cc_library target, and the base name for
              generated header file
        binary: binary file to be embedded
        array_variable_name: name of the constant array for the data.
    """
    cc_name = "%s.cc" % name
    h_name = "%s.h" % name
    native.genrule(
        name = name + "_src",
        srcs = [binary],
        outs = [
            cc_name,
            h_name,
        ],
        cmd = """
      $(location //tensorflow/lite/experimental/acceleration/compatibility:convert_binary_to_cc_source) \
          --input_binary_file $(location %s) \
          --output_header_file $(location :%s) \
          --output_source_file $(location :%s) \
          --array_variable_name %s
      """ % (binary, h_name, cc_name, array_variable_name),
        tools = ["//tensorflow/lite/experimental/acceleration/compatibility:convert_binary_to_cc_source"],
        testonly = testonly,
    )

    native.cc_library(
        name = name,
        srcs = [cc_name],
        hdrs = [h_name],
        testonly = testonly,
        exec_properties = exec_properties,
    )

def validation_model(
        name,
        main_model,
        metrics_model,
        jpegs,
        scale = "",
        zeropoint = "",
        use_ondevice_cpu_for_golden = False,
        testonly = 0):
    """Create a tflite model with embedded validation.

    Args:
        name: name of the target. A file called 'name'.tflite is generated
        main_model: main tflite model target
        metrics_model: metrics tflite model target
        jpegs: target with 1 or more jpeg files
        scale: the input (de)quantization scale parameter for float models
        zeropoint: the input (de)quantization zeropoint parameter for float models
        use_ondevice_cpu_for_golden: use on-device CPU for golden data (rather than embedding)
        testonly: whether target is marked testonly
    """
    if use_ondevice_cpu_for_golden:
        use_ondevice_cpu_for_golden = "true"
    else:
        use_ondevice_cpu_for_golden = "false"
    scale_arg = ""
    zeropoint_arg = ""
    if scale:
        scale_arg = "--scale=" + scale
        zeropoint_arg = "--zero_point=" + zeropoint
    native.genrule(
        name = name,
        testonly = testonly,
        srcs = [
            main_model,
            jpegs,
            "//tensorflow/lite/schema:schema.fbs",
            metrics_model,
        ],
        outs = [name + ".tflite"],
        cmd = """
          JPEGS='$(locations %s)'
          JPEGS=$${JPEGS// /,}
          $(location //tensorflow/lite/experimental/acceleration/mini_benchmark/model_modifier:embedder_cmdline) \
              --schema=$(location //tensorflow/lite/schema:schema.fbs) \
              --main_model=$(location %s) \
              --metrics_model=$(location %s) \
              %s %s \
              --jpegs=$$JPEGS \
              --use_ondevice_cpu_for_golden=%s \
              --output='$(@D)/%s.tflite.tmp'
          $(location //tensorflow/lite/experimental/acceleration/mini_benchmark:copy_associated_files) \
              '$(@D)/%s.tflite.tmp' \
              $(location %s) \
              $(location %s.tflite)
          rm '$(@D)/%s.tflite.tmp'
        """ % (
            jpegs,
            main_model,
            metrics_model,
            scale_arg,
            zeropoint_arg,
            use_ondevice_cpu_for_golden,
            name,
            name,
            main_model,
            name,
            name,
        ),
        tools = [
            "//tensorflow/lite/experimental/acceleration/mini_benchmark/model_modifier:embedder_cmdline",
            "//tensorflow/lite/experimental/acceleration/mini_benchmark:copy_associated_files",
        ],
    )

def validation_test(name, validation_model, tags = [], copts = [], deps = []):
    """Create a test binary for the given model with validation.

    Args:
        name: name of the target.
        validation_model: tflite model with validation target.
        tags: to be passed to cc_test.
        copts: to be passed to cc_test.
        deps: to be passed to cc_test.
    """
    embed_name = name + "_embed_model"
    embedded_binary(
        embed_name,
        binary = validation_model,
        array_variable_name = "g_tflite_acceleration_" + name + "_model",
    )
    native.cc_test(
        name = name,
        srcs = ["//tensorflow/lite/experimental/acceleration/mini_benchmark:model_validation_test.cc"],
        tags = tags + ["no_mac", "no_windows", "tflite_not_portable_ios"],
        copts = copts + [
            "-DTENSORFLOW_ACCELERATION_MODEL_DATA_VARIABLE=\"g_tflite_acceleration_%s_model\"" % name,
            "-DTENSORFLOW_ACCELERATION_MODEL_LENGTH_VARIABLE=\"g_tflite_acceleration_%s_model_len\"" % name,
        ],
        deps = deps + [
            embed_name,
            "@com_google_googletest//:gtest_main",
            "@flatbuffers",
            "//tensorflow/lite/acceleration/configuration:configuration_fbs",
            "//tensorflow/lite/acceleration/configuration:nnapi_plugin",
            "//tensorflow/lite/experimental/acceleration/compatibility:android_info",
            "//tensorflow/lite/experimental/acceleration/mini_benchmark:big_little_affinity",
            "//tensorflow/lite/experimental/acceleration/mini_benchmark:status_codes",
            "//tensorflow/lite/experimental/acceleration/mini_benchmark:validator",
            "//tensorflow/lite/tools:model_loader",
        ] + select({
            clean_dep("//tensorflow:android"): [
                "//tensorflow/lite/acceleration/configuration:gpu_plugin",
            ],
            "//conditions:default": [],
        }) + libjpeg_handle_deps(),
        linkstatic = 1,
    )

def cc_library_with_forced_in_process_benchmark_variant(
        name,
        deps = [],
        in_process_deps = [],
        **kwargs):
    """Defines a cc_library that optionally forces benchmark runs in process.

    This generates two cc_library target. The first one runs the benchmark in a
    separate process on Android, while it runs the benchmark in process on all
    other platforms. The second one, which has "_in_process" appended to the
    name, forces benchmark runs in process.

    Args:
      name: determines the name used for the generated cc_library targets.
      deps: dependencies that will be unconditionally included in the deps of
        the generated cc_library targets.
      in_process_deps: dependencies on rules that are themselves defined using
        'cc_library_with_forced_in_process_benchmark_variant'. Must be
        iterable, so cannot be computed by calling 'select'.
      **kwargs:
        Additional cc_library parameters.
    """
    native.cc_library(
        name = name,
        deps = deps + in_process_deps + [
            clean_dep("//tensorflow/lite/experimental/acceleration/mini_benchmark:tflite_acceleration_in_process_default"),
        ],
        **kwargs
    )

    in_process_deps_renamed = [add_suffix(in_process_dep, "_in_process") for in_process_dep in in_process_deps]
    native.cc_library(
        name = name + "_in_process",
        deps = deps + in_process_deps_renamed + [
            clean_dep("//tensorflow/lite/experimental/acceleration/mini_benchmark:tflite_acceleration_in_process_enable"),
        ],
        **kwargs
    )
