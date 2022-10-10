# Copyright (C) 2022 The Android Open Source Project
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

load("@bazel_skylib//lib:paths.bzl", "paths")
load("@bazel_skylib//lib:sets.bzl", "sets")
load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("//build/kernel/kleaf:hermetic_tools.bzl", "HermeticToolsInfo")
load(
    "//build/kernel/kleaf/artifact_tests:kernel_test.bzl",
    "kernel_build_test",
    "kernel_module_test",
)
load(":btf.bzl", "btf")
load(
    ":common_providers.bzl",
    "KernelBuildAbiInfo",
    "KernelBuildExtModuleInfo",
    "KernelBuildInTreeModulesInfo",
    "KernelBuildInfo",
    "KernelBuildMixedTreeInfo",
    "KernelBuildUapiInfo",
    "KernelEnvAttrInfo",
    "KernelEnvInfo",
    "KernelImagesInfo",
    "KernelUnstrippedModulesInfo",
)
load(
    ":constants.bzl",
    "MODULES_STAGING_ARCHIVE",
    "MODULE_OUTS_FILE_OUTPUT_GROUP",
    "MODULE_OUTS_FILE_SUFFIX",
    "TOOLCHAIN_VERSION_FILENAME",
)
load(":debug.bzl", "debug")
load(":kernel_config.bzl", "kernel_config")
load(":kernel_env.bzl", "kernel_env")
load(":kernel_headers.bzl", "kernel_headers")
load(":kernel_toolchain_aspect.bzl", "KernelToolchainInfo", "kernel_toolchain_aspect")
load(":kernel_uapi_headers.bzl", "kernel_uapi_headers")
load(":kmi_symbol_list.bzl", _kmi_symbol_list = "kmi_symbol_list")
load(":modules_prepare.bzl", "modules_prepare")
load(":raw_kmi_symbol_list.bzl", "raw_kmi_symbol_list")
load(":utils.bzl", "kernel_utils", "utils")

# Outputs of a kernel_build rule needed to build kernel_* that depends on it
_kernel_build_internal_outs = [
    "Module.symvers",
    "include/config/kernel.release",
]

_KERNEL_BUILD_OUT_ATTRS = ("outs", "module_outs", "implicit_outs", "module_implicit_outs", "internal_outs")
_KERNEL_BUILD_MODULE_OUT_ATTRS = ("module_outs", "module_implicit_outs")

def kernel_build(
        name,
        build_config,
        outs,
        srcs = None,
        module_outs = None,
        implicit_outs = None,
        module_implicit_outs = None,
        generate_vmlinux_btf = None,
        deps = None,
        base_kernel = None,
        base_kernel_for_module_outs = None,
        kconfig_ext = None,
        dtstree = None,
        kmi_symbol_list = None,
        additional_kmi_symbol_lists = None,
        trim_nonlisted_kmi = None,
        kmi_symbol_list_strict_mode = None,
        collect_unstripped_modules = None,
        enable_interceptor = None,
        kbuild_symtypes = None,
        toolchain_version = None,
        strip_modules = None,
        **kwargs):
    """Defines a kernel build target with all dependent targets.

    It uses a `build_config` to construct a deterministic build environment (e.g.
    `common/build.config.gki.aarch64`). The kernel sources need to be declared
    via srcs (using a `glob()`). outs declares the output files that are surviving
    the build. The effective output file names will be
    `$(name)/$(output_file)`. Any other artifact is not guaranteed to be
    accessible after the rule has run. The default `toolchain_version` is defined
    with the value in `common/build.config.constants`, but can be overriden.

    A few additional labels are generated.
    For example, if name is `"kernel_aarch64"`:
    - `kernel_aarch64_uapi_headers` provides the UAPI kernel headers.
    - `kernel_aarch64_headers` provides the kernel headers.

    Args:
        name: The final kernel target name, e.g. `"kernel_aarch64"`.
        build_config: Label of the build.config file, e.g. `"build.config.gki.aarch64"`.
        kconfig_ext: Label of an external Kconfig.ext file sourced by the GKI kernel.
        srcs: The kernel sources (a `glob()`). If unspecified or `None`, it is the following:
          ```
          glob(
              ["**"],
              exclude = [
                  "**/.*",          # Hidden files
                  "**/.*/**",       # Files in hidden directories
                  "**/BUILD.bazel", # build files
                  "**/*.bzl",       # build files
              ],
          )
          ```
        base_kernel: A label referring the base kernel build.

          If set, the list of files specified in the `DefaultInfo` of the rule specified in
          `base_kernel` is copied to a directory, and `KBUILD_MIXED_TREE` is set to the directory.
          Setting `KBUILD_MIXED_TREE` effectively enables mixed build.

          To set additional flags for mixed build, change `build_config` to a `kernel_build_config`
          rule, with a build config fragment that contains the additional flags.

          The label specified by `base_kernel` must produce a list of files similar
          to what a `kernel_build` rule does. Usually, this points to one of the following:
          - `//common:kernel_{arch}`
          - A `kernel_filegroup` rule, e.g.
            ```
            load("//build/kernel/kleaf:constants.bzl, "aarch64_outs")
            kernel_filegroup(
              name = "my_kernel_filegroup",
              srcs = aarch64_outs,
            )
            ```
        base_kernel_for_module_outs: **INTERNAL ONLY; DO NOT SET!**

          If set, this is used instead of `base_kernel` to determine the list
          of GKI modules.
        generate_vmlinux_btf: If `True`, generates `vmlinux.btf` that is stripped of any debug
          symbols, but contains type and symbol information within a .BTF section.
          This is suitable for ABI analysis through BTF.

          Requires that `"vmlinux"` is in `outs`.
        deps: Additional dependencies to build this kernel.
        module_outs: A list of in-tree drivers. Similar to `outs`, but for `*.ko` files.

          If a `*.ko` kernel module should not be copied to `${DIST_DIR}`, it must be
          included `implicit_outs` instead of `module_outs`. The list `implicit_outs + module_outs`
          must include **all** `*.ko` files in `${OUT_DIR}`. If not, a build error is raised.

          Like `outs`, `module_outs` are part of the
          [`DefaultInfo`](https://docs.bazel.build/versions/main/skylark/lib/DefaultInfo.html)
          that this `kernel_build` returns. For example:
          ```
          kernel_build(name = "kernel", module_outs = ["foo.ko"], ...)
          copy_to_dist_dir(name = "kernel_dist", data = [":kernel"])
          ```
          `foo.ko` will be included in the distribution.

          Like `outs`, this may be a `dict`. If so, it is wrapped in
          [`select()`](https://docs.bazel.build/versions/main/configurable-attributes.html). See
          documentation for `outs` for more details.
        outs: The expected output files.

          Note: in-tree modules should be specified in `module_outs` instead.

          This attribute must be either a `dict` or a `list`. If it is a `list`, for each item
          in `out`:

          - If `out` does not contain a slash, the build rule
            automatically finds a file with name `out` in the kernel
            build output directory `${OUT_DIR}`.
            ```
            find ${OUT_DIR} -name {out}
            ```
            There must be exactly one match.
            The file is copied to the following in the output directory
            `{name}/{out}`

            Example:
            ```
            kernel_build(name = "kernel_aarch64", outs = ["vmlinux"])
            ```
            The bulid system copies `${OUT_DIR}/[<optional subdirectory>/]vmlinux`
            to `kernel_aarch64/vmlinux`.
            `kernel_aarch64/vmlinux` is the label to the file.

          - If `out` contains a slash, the build rule locates the file in the
            kernel build output directory `${OUT_DIR}` with path `out`
            The file is copied to the following in the output directory
              1. `{name}/{out}`
              2. `{name}/$(basename {out})`

            Example:
            ```
            kernel_build(
              name = "kernel_aarch64",
              outs = ["arch/arm64/boot/vmlinux"])
            ```
            The bulid system copies
              `${OUT_DIR}/arch/arm64/boot/vmlinux`
            to:
              - `kernel_aarch64/arch/arm64/boot/vmlinux`
              - `kernel_aarch64/vmlinux`
            They are also the labels to the output files, respectively.

            See `search_and_cp_output.py` for details.

          Files in `outs` are part of the
          [`DefaultInfo`](https://docs.bazel.build/versions/main/skylark/lib/DefaultInfo.html)
          that this `kernel_build` returns. For example:
          ```
          kernel_build(name = "kernel", outs = ["vmlinux"], ...)
          copy_to_dist_dir(name = "kernel_dist", data = [":kernel"])
          ```
          `vmlinux` will be included in the distribution.

          If it is a `dict`, it is wrapped in
          [`select()`](https://docs.bazel.build/versions/main/configurable-attributes.html).

          Example:
          ```
          kernel_build(
            name = "kernel_aarch64",
            outs = {"config_foo": ["vmlinux"]})
          ```
          If conditions in `config_foo` is met, the rule is equivalent to
          ```
          kernel_build(
            name = "kernel_aarch64",
            outs = ["vmlinux"])
          ```
          As explained above, the bulid system copies `${OUT_DIR}/[<optional subdirectory>/]vmlinux`
          to `kernel_aarch64/vmlinux`.
          `kernel_aarch64/vmlinux` is the label to the file.

          Note that a `select()` may not be passed into `kernel_build()` because
          [`select()` cannot be evaluated in macros](https://docs.bazel.build/versions/main/configurable-attributes.html#why-doesnt-select-work-in-macros).
          Hence:
          - [combining `select()`s](https://docs.bazel.build/versions/main/configurable-attributes.html#combining-selects)
            is not allowed. Instead, expand the cartesian product.
          - To use
            [`AND` chaining](https://docs.bazel.build/versions/main/configurable-attributes.html#or-chaining)
            or
            [`OR` chaining](https://docs.bazel.build/versions/main/configurable-attributes.html#selectsconfig_setting_group),
            use `selects.config_setting_group()`.

        implicit_outs: Like `outs`, but not copied to the distribution directory.

          Labels are created for each item in `implicit_outs` as in `outs`.

        module_implicit_outs: like `module_outs`, but not copied to the distribution directory.

          Labels are created for each item in `module_implicit_outs` as in `outs`.

        kmi_symbol_list: A label referring to the main KMI symbol list file. See `additional_kmi_symbol_list`.

          This is the Bazel equivalent of `ADDTIONAL_KMI_SYMBOL_LISTS`.
        additional_kmi_symbol_list: A list of labels referring to additional KMI symbol list files.

          This is the Bazel equivalent of `ADDTIONAL_KMI_SYMBOL_LISTS`.

          Let
          ```
          all_kmi_symbol_lists = [kmi_symbol_list] + additional_kmi_symbol_list
          ```

          If `all_kmi_symbol_lists` is a non-empty list, `abi_symbollist` and
          `abi_symbollist.report` are created and added to the
          [`DefaultInfo`](https://docs.bazel.build/versions/main/skylark/lib/DefaultInfo.html),
          and copied to `DIST_DIR` during distribution.

          If `all_kmi_symbol_lists` is `None` or an empty list, `abi_symbollist` and
          `abi_symbollist.report` are not created.

          It is possible to use a `glob()` to determine whether `abi_symbollist`
          and `abi_symbollist.report` should be generated at build time.
          For example:
          ```
          kmi_symbol_list = "android/abi_gki_aarch64",
          additional_kmi_symbol_lists = glob(["android/abi_gki_aarch64*"], exclude = ["android/abi_gki_aarch64"]),
          ```
        trim_nonlisted_kmi: If `True`, trim symbols not listed in
          `kmi_symbol_list` and `additional_kmi_symbol_lists`.
          This is the Bazel equivalent of `TRIM_NONLISTED_KMI`.

          Requires `all_kmi_symbol_lists` to be non-empty. If `kmi_symbol_list`
          or `additional_kmi_symbol_lists`
          is a `glob()`, it is possible to set `trim_nonlisted_kmi` to be a
          value based on that `glob()`. For example:
          ```
          trim_nonlisted_kmi = len(glob(["android/abi_gki_aarch64*"])) > 0
          ```
        kmi_symbol_list_strict_mode: If `True`, add a build-time check between
          `[kmi_symbol_list] + additional_kmi_symbol_lists`
          and the KMI resulting from the build, to ensure
          they match 1-1.
        collect_unstripped_modules: If `True`, provide all unstripped in-tree.

          Approximately equivalent to `UNSTRIPPED_MODULES=*` in `build.sh`.
        enable_interceptor: If set to `True`, enable interceptor so it can be
          used in [`kernel_compile_commands`](#kernel_compile_commands).
        kbuild_symtypes: The value of `KBUILD_SYMTYPES`.

          This can be set to one of the following:

          - `"true"`
          - `"false"`
          - `"auto"`
          - `None`, which defaults to `"auto"`

          If the value is `"auto"`, it is determined by the `--kbuild_symtypes`
          flag.

          If the value is `"true"`; or the value is `"auto"` and
          `--kbuild_symtypes` is specified, then `KBUILD_SYMTYPES=1`.
          **Note**: kernel build time can be significantly longer.

          If the value is `"false"`; or the value is `"auto"` and
          `--kbuild_symtypes` is not specified, then `KBUILD_SYMTYPES=`.
        toolchain_version: The toolchain version to depend on.
        strip_modules: If `None` or not specified, default is `False`.
          If set to `True`, debug information for distributed modules is stripped.

          This corresponds to negated value of `DO_NOT_STRIP_MODULES` in `build.config`.
        kwargs: Additional attributes to the internal rule, e.g.
          [`visibility`](https://docs.bazel.build/versions/main/visibility.html).
          See complete list
          [here](https://docs.bazel.build/versions/main/be/common-definitions.html#common-attributes).
    """
    env_target_name = name + "_env"
    config_target_name = name + "_config"
    modules_prepare_target_name = name + "_modules_prepare"
    uapi_headers_target_name = name + "_uapi_headers"
    headers_target_name = name + "_headers"
    kmi_symbol_list_target_name = name + "_kmi_symbol_list"
    abi_symbollist_target_name = name + "_kmi_symbol_list_abi_symbollist"
    raw_kmi_symbol_list_target_name = name + "_raw_kmi_symbol_list"

    if srcs == None:
        srcs = native.glob(
            ["**"],
            exclude = [
                "**/.*",
                "**/.*/**",
                "**/BUILD.bazel",
                "**/*.bzl",
            ],
        )

    if strip_modules == None:
        strip_modules = False

    internal_kwargs = dict(kwargs)
    internal_kwargs.pop("visibility", default = None)

    kwargs_with_manual = dict(kwargs)
    kwargs_with_manual["tags"] = ["manual"]

    kernel_env(
        name = env_target_name,
        build_config = build_config,
        kconfig_ext = kconfig_ext,
        dtstree = dtstree,
        srcs = srcs,
        toolchain_version = toolchain_version,
        kbuild_symtypes = kbuild_symtypes,
        **internal_kwargs
    )

    all_kmi_symbol_lists = []
    if kmi_symbol_list:
        all_kmi_symbol_lists.append(kmi_symbol_list)
    if additional_kmi_symbol_lists:
        all_kmi_symbol_lists += additional_kmi_symbol_lists

    _kmi_symbol_list(
        name = kmi_symbol_list_target_name,
        env = env_target_name,
        srcs = all_kmi_symbol_lists,
        **internal_kwargs
    )

    native.filegroup(
        name = abi_symbollist_target_name,
        srcs = [kmi_symbol_list_target_name],
        output_group = "abi_symbollist",
        **internal_kwargs
    )

    raw_kmi_symbol_list(
        name = raw_kmi_symbol_list_target_name,
        env = env_target_name,
        src = abi_symbollist_target_name if all_kmi_symbol_lists else None,
        **internal_kwargs
    )

    kernel_config(
        name = config_target_name,
        env = env_target_name,
        srcs = srcs,
        config = config_target_name + "/.config",
        trim_nonlisted_kmi = trim_nonlisted_kmi,
        raw_kmi_symbol_list = raw_kmi_symbol_list_target_name if all_kmi_symbol_lists else None,
        **internal_kwargs
    )

    modules_prepare(
        name = modules_prepare_target_name,
        config = config_target_name,
        srcs = srcs,
        outdir_tar_gz = modules_prepare_target_name + "/modules_prepare_outdir.tar.gz",
        **internal_kwargs
    )

    _kernel_build(
        name = name,
        config = config_target_name,
        srcs = srcs,
        outs = kernel_utils.transform_kernel_build_outs(name, "outs", outs),
        module_outs = kernel_utils.transform_kernel_build_outs(name, "module_outs", module_outs),
        implicit_outs = kernel_utils.transform_kernel_build_outs(name, "implicit_outs", implicit_outs),
        module_implicit_outs = kernel_utils.transform_kernel_build_outs(name, "module_implicit_outs", module_implicit_outs),
        internal_outs = kernel_utils.transform_kernel_build_outs(name, "internal_outs", _kernel_build_internal_outs),
        deps = deps,
        base_kernel = base_kernel,
        base_kernel_for_module_outs = base_kernel_for_module_outs,
        modules_prepare = modules_prepare_target_name,
        kmi_symbol_list_strict_mode = kmi_symbol_list_strict_mode,
        raw_kmi_symbol_list = raw_kmi_symbol_list_target_name if all_kmi_symbol_lists else None,
        kernel_uapi_headers = uapi_headers_target_name,
        collect_unstripped_modules = collect_unstripped_modules,
        combined_abi_symbollist = abi_symbollist_target_name if all_kmi_symbol_lists else None,
        enable_interceptor = enable_interceptor,
        strip_modules = strip_modules,
        **kwargs
    )

    # key = attribute name, value = a list of labels for that attribute
    real_outs = {}

    for out_name, out_attr_val in (
        ("outs", outs),
        ("module_outs", module_outs),
        ("implicit_outs", implicit_outs),
        ("module_implicit_outs", module_implicit_outs),
        # internal_outs are opaque to the user, hence we don't create a alias (filegroup) for them.
    ):
        if out_attr_val == None:
            continue
        if type(out_attr_val) == type([]):
            for out in out_attr_val:
                native.filegroup(name = name + "/" + out, srcs = [":" + name], output_group = out, **kwargs)
                if out != paths.basename(out):
                    native.filegroup(name = name + "/" + paths.basename(out), srcs = [":" + name], output_group = out, **kwargs)
            real_outs[out_name] = [name + "/" + out for out in out_attr_val]
        elif type(out_attr_val) == type({}):
            # out_attr_val = {config_setting: [out, ...], ...}
            # => reverse_dict = {out: [config_setting, ...], ...}
            for out, config_settings in utils.reverse_dict(out_attr_val).items():
                native.filegroup(
                    name = name + "/" + out,
                    # Use a select() to prevent this rule to build when config_setting is not fulfilled.
                    srcs = select({
                        config_setting: [":" + name]
                        for config_setting in config_settings
                    }),
                    output_group = out,
                    # Use "manual" tags to prevent it to be built with ...
                    **kwargs_with_manual
                )
                if out != paths.basename(out):
                    native.filegroup(
                        name = name + "/" + paths.basename(out),
                        # Use a select() to prevent this rule to build when config_setting is not fulfilled.
                        srcs = select({
                            config_setting: [":" + name]
                            for config_setting in config_settings
                        }),
                        output_group = out,
                        # Use "manual" tags to prevent it to be built with ...
                        **kwargs_with_manual
                    )
            real_outs[out_name] = [name + "/" + out for out, _ in utils.reverse_dict(out_attr_val).items()]
        else:
            fail("Unexpected type {} for {}: {}".format(type(out_attr_val), out_name, out_attr_val))

    kernel_uapi_headers(
        name = uapi_headers_target_name,
        config = config_target_name,
        srcs = srcs,
        **kwargs
    )

    kernel_headers(
        name = headers_target_name,
        kernel_build = name,
        env = env_target_name,
        # TODO: We need arch/ and include/ only.
        srcs = srcs,
        **kwargs
    )

    if generate_vmlinux_btf:
        btf_name = name + "_btf"
        btf(
            name = btf_name,
            vmlinux = name + "/vmlinux",
            env = env_target_name,
            **kwargs
        )

    kernel_build_test(
        name = name + "_test",
        target = name,
        **kwargs
    )

    kernel_module_test(
        name = name + "_modules_test",
        modules = (real_outs.get("module_outs") or []) + (real_outs.get("module_implicit_outs") or []),
        **kwargs
    )

def _uniq(lst):
    """Deduplicates items in lst."""
    return sets.to_list(sets.make(lst))

def _path_or_empty(file):
    """Returns path of the file if it is not `None`, otherwise empty string."""
    if not file:
        return ""
    return file.path

def _create_kbuild_mixed_tree(ctx):
    """Adds actions that creates the `KBUILD_MIXED_TREE`."""
    base_kernel_files = depset()
    outputs = []
    kbuild_mixed_tree = None
    cmd = ""
    arg = ""
    env_info_setup = ""
    if ctx.attr.base_kernel:
        # Create a directory for KBUILD_MIXED_TREE. Flatten the directory structure of the files
        # that ctx.attr.base_kernel provides. declare_directory is sufficient because the directory should
        # only change when the dependent ctx.attr.base_kernel changes.
        kbuild_mixed_tree = ctx.actions.declare_directory("{}_kbuild_mixed_tree".format(ctx.label.name))
        outputs = [kbuild_mixed_tree]
        base_kernel_files = ctx.attr.base_kernel[KernelBuildMixedTreeInfo].files
        kbuild_mixed_tree_command = ctx.attr._hermetic_tools[HermeticToolsInfo].setup + """
          # Restore GKI artifacts for mixed build
            export KBUILD_MIXED_TREE=$(realpath {kbuild_mixed_tree})
            rm -rf ${{KBUILD_MIXED_TREE}}
            mkdir -p ${{KBUILD_MIXED_TREE}}
            for base_kernel_file in {base_kernel_files}; do
              ln -s $(readlink -m ${{base_kernel_file}}) ${{KBUILD_MIXED_TREE}}
            done
        """.format(
            base_kernel_files = " ".join([file.path for file in base_kernel_files.to_list()]),
            kbuild_mixed_tree = kbuild_mixed_tree.path,
        )
        debug.print_scripts(ctx, kbuild_mixed_tree_command, what = "kbuild_mixed_tree")
        ctx.actions.run_shell(
            mnemonic = "KernelBuildKbuildMixedTree",
            inputs = depset(ctx.attr._hermetic_tools[HermeticToolsInfo].deps, transitive = [base_kernel_files]),
            outputs = [kbuild_mixed_tree],
            progress_message = "Creating KBUILD_MIXED_TREE",
            command = kbuild_mixed_tree_command,
        )

        cmd = """
            export KBUILD_MIXED_TREE=$(realpath {kbuild_mixed_tree})
        """.format(
            kbuild_mixed_tree = kbuild_mixed_tree.path,
        )

        arg = "--srcdir ${KBUILD_MIXED_TREE}"
    return struct(
        outputs = outputs,
        cmd = cmd,
        base_kernel_files = base_kernel_files,
        arg = arg,
    )

def _get_base_kernel_all_module_names_file(ctx):
    """Returns the file containing all module names from the base kernel or None if there's no base_kernel."""
    base_kernel_for_module_outs = ctx.attr.base_kernel_for_module_outs
    if base_kernel_for_module_outs == None:
        base_kernel_for_module_outs = ctx.attr.base_kernel
    if base_kernel_for_module_outs:
        base_kernel_all_module_names_file = base_kernel_for_module_outs[KernelBuildInTreeModulesInfo].module_outs_file
        if not base_kernel_all_module_names_file:
            fail("{}: base_kernel {} does not provide module_outs_file.".format(ctx.label, ctx.attr.base_kernel.label))
        return base_kernel_all_module_names_file
    return None

def _declare_all_output_files(ctx):
    """Declares output files based on `ctx.attr.*outs`."""

    # kernel_build(name="kernel", outs=["out"])
    # => _kernel_build(name="kernel", outs=["kernel/out"], internal_outs=["kernel/Module.symvers", ...])
    # => all_output_names = ["foo", "Module.symvers", ...]
    #    all_output_files = {"out": {"foo": File(...)}, "internal_outs": {"Module.symvers": File(...)}, ...}
    all_output_files = {}
    for attr in _KERNEL_BUILD_OUT_ATTRS:
        all_output_files[attr] = {name: ctx.actions.declare_file("{}/{}".format(ctx.label.name, name)) for name in getattr(ctx.attr, attr)}
    return all_output_files

def _split_out_attrs(ctx):
    """Partitions items in *outs into two lists: non-modules and modules."""
    non_modules = []
    modules = []
    for attr in _KERNEL_BUILD_OUT_ATTRS:
        if attr in _KERNEL_BUILD_MODULE_OUT_ATTRS:
            modules += getattr(ctx.attr, attr)
        else:
            non_modules += getattr(ctx.attr, attr)
    return struct(
        non_modules = non_modules,
        modules = modules,
    )

def _write_module_names_to_file(ctx, filename, names):
    """Adds an action that writes |names| to a file named |filename|. Each item occupies a line."""
    all_module_names_file = ctx.actions.declare_file("{}_all_module_names/{}".format(ctx.label.name, filename))
    ctx.actions.write(
        output = all_module_names_file,
        content = "\n".join(names) + "\n",
    )
    return all_module_names_file

# A "step" contains these fields:
#
# * inputs: a list of source files for this step
# * tools: a list of required tools for this step
# * outputs: a list of generated files for this step
# * cmd (optional): the command for this step
# * Other special fields.
#
# In other words, a step is a weaker form of an [Action](https://bazel.build/rules/lib/Action),
# but because the `OUT_DIR` needs to be kept between the steps, they are stuffed into the main
# action.

def _get_interceptor_step(ctx):
    """Returns a step for interceptor.

    This is a special step that doesn't have a `cmd`, but provides a `command_prefix` instead.

    Returns:
      A struct with these fields:

      * inputs
      * tools
      * outputs
      * command_prefix
      * output_file
    """
    interceptor_output = None
    interceptor_command_prefix = ""
    if ctx.attr.enable_interceptor:
        interceptor_output = ctx.actions.declare_file("{name}/interceptor_output.bin".format(name = ctx.label.name))
        interceptor_command_prefix = "interceptor -r -l {interceptor_output} --".format(
            interceptor_output = interceptor_output.path,
        )
    return struct(
        inputs = [],
        tools = [],
        outputs = [interceptor_output] if interceptor_output else [],
        command_prefix = interceptor_command_prefix,
        output_file = interceptor_output,
    )

def _get_cache_dir_step(ctx):
    """Returns a step for caching the output directory.

    Returns:
      A struct with these fields:

      * inputs
      * tools
      * cmd
      * outputs
    """

    # Use a local cache directory for ${OUT_DIR} so that, even when this _kernel_build
    # target needs to be rebuilt, we are using $OUT_DIR from previous invocations. This
    # boosts --config=local builds. See (b/235632059).
    cache_dir_cmd = ""
    if ctx.attr._config_is_local[BuildSettingInfo].value:
        if not ctx.attr._cache_dir[BuildSettingInfo].value:
            fail("--config=local requires --cache_dir.")
        cache_dir_cmd = """
              KLEAF_CACHED_OUT_DIR={cache_dir}/{name}
              mkdir -p "${{KLEAF_CACHED_OUT_DIR}}"
              rsync -aL "${{OUT_DIR}}/" "${{KLEAF_CACHED_OUT_DIR}}/"
              export OUT_DIR=${{KLEAF_CACHED_OUT_DIR}}
              unset KLEAF_CACHED_OUT_DIR
        """.format(
            cache_dir = ctx.attr._cache_dir[BuildSettingInfo].value,
            name = utils.sanitize_label_as_filename(ctx.label),
        )
    return struct(inputs = [], tools = [], cmd = cache_dir_cmd, outputs = [])

def _get_grab_intree_modules_step(ctx, has_any_modules, modules_staging_dir, ruledir, all_module_names_file):
    """Returns a step for grabbing the in-tree modules from `OUT_DIR`.

    Returns:
      A struct with these fields:

      * inputs
      * tools
      * cmd
      * outputs
    """
    tools = []
    grab_intree_modules_cmd = ""
    if has_any_modules:
        tools.append(ctx.file._search_and_cp_output)
        grab_intree_modules_cmd = """
            {search_and_cp_output} --srcdir {modules_staging_dir}/lib/modules/*/kernel --dstdir {ruledir} $(cat {all_module_names_file})
        """.format(
            search_and_cp_output = ctx.file._search_and_cp_output.path,
            modules_staging_dir = modules_staging_dir,
            ruledir = ruledir.path,
            all_module_names_file = all_module_names_file.path,
        )
    return struct(
        inputs = [],
        tools = tools,
        cmd = grab_intree_modules_cmd,
        outputs = [],
    )

def _get_grab_unstripped_modules_step(ctx, has_any_modules, all_module_basenames_file):
    """Returns a step for grabbing the unstripped in-tree modules from `OUT_DIR`.

    Returns:
      A struct with these fields:

      * inputs
      * tools
      * cmd
      * outputs
      * unstripped_dir: A [File](https://bazel.build/rules/lib/File), which is a directory pointing
        to a directory containing the unstripped modules.
    """
    grab_unstripped_intree_modules_cmd = ""
    inputs = []
    tools = []
    outputs = []
    unstripped_dir = None

    if ctx.attr.collect_unstripped_modules:
        unstripped_dir = ctx.actions.declare_directory("{name}/unstripped".format(name = ctx.label.name))
        outputs.append(unstripped_dir)

        if has_any_modules:
            tools.append(ctx.file._search_and_cp_output)
            inputs.append(all_module_basenames_file)
            grab_unstripped_intree_modules_cmd = """
                mkdir -p {unstripped_dir}
                {search_and_cp_output} --srcdir ${{OUT_DIR}} --dstdir {unstripped_dir} $(cat {all_module_basenames_file})
            """.format(
                search_and_cp_output = ctx.file._search_and_cp_output.path,
                unstripped_dir = unstripped_dir.path,
                all_module_basenames_file = all_module_basenames_file.path,
            )

    return struct(
        inputs = inputs,
        tools = tools,
        cmd = grab_unstripped_intree_modules_cmd,
        outputs = outputs,
        unstripped_dir = unstripped_dir,
    )

def _get_grab_symtypes_step(ctx):
    """Returns a step for grabbing the `*.symtypes` from `OUT_DIR`.

    Returns:
      A struct with these fields:

      * inputs
      * tools
      * outputs
      * cmd
    """
    grab_symtypes_cmd = ""
    outputs = []
    if ctx.attr.config[KernelEnvAttrInfo].kbuild_symtypes:
        symtypes_dir = ctx.actions.declare_directory("{name}/symtypes".format(name = ctx.label.name))
        outputs.append(symtypes_dir)
        grab_symtypes_cmd = """
            rsync -a --prune-empty-dirs --include '*/' --include '*.symtypes' --exclude '*' ${{OUT_DIR}}/ {symtypes_dir}/
        """.format(
            symtypes_dir = symtypes_dir.path,
        )
    return struct(
        inputs = [],
        tools = [],
        cmd = grab_symtypes_cmd,
        outputs = outputs,
    )

def _build_main_action(
        ctx,
        kbuild_mixed_tree_ret,
        all_output_names,
        all_module_names_file,
        all_module_basenames_file,
        check_toolchain_outs):
    """Adds the main action for the `kernel_build`."""
    base_kernel_all_module_names_file = _get_base_kernel_all_module_names_file(ctx)

    # Declare outputs.
    ## Declare outputs based on the *outs attributes
    all_output_files = _declare_all_output_files(ctx)

    ## Declare implicit outputs of the command
    ruledir = ctx.actions.declare_directory(ctx.label.name)

    if ctx.attr.base_kernel:
        # We will re-package MODULES_STAGING_ARCHIVE in _repack_module_staging_archive,
        # so use a different name.
        modules_staging_archive_self = ctx.actions.declare_file(
            "{}/modules_staging_dir_self.tar.gz".format(ctx.label.name),
        )
    else:
        modules_staging_archive_self = ctx.actions.declare_file(
            "{}/{}".format(ctx.label.name, MODULES_STAGING_ARCHIVE),
        )

    out_dir_kernel_headers_tar = ctx.actions.declare_file(
        "{name}/out-dir-kernel-headers.tar.gz".format(name = ctx.label.name),
    )

    modules_staging_dir = modules_staging_archive_self.dirname + "/staging"

    # Individual steps of the final command.
    interceptor_step = _get_interceptor_step(ctx)
    cache_dir_step = _get_cache_dir_step(ctx)
    grab_intree_modules_step = _get_grab_intree_modules_step(
        ctx = ctx,
        has_any_modules = bool(all_output_names.modules),
        modules_staging_dir = modules_staging_dir,
        ruledir = ruledir,
        all_module_names_file = all_module_names_file,
    )
    grab_unstripped_modules_step = _get_grab_unstripped_modules_step(
        ctx = ctx,
        has_any_modules = bool(all_output_names.modules),
        all_module_basenames_file = all_module_basenames_file,
    )
    grab_symtypes_step = _get_grab_symtypes_step(ctx)
    steps = (
        interceptor_step,
        cache_dir_step,
        grab_intree_modules_step,
        grab_unstripped_modules_step,
        grab_symtypes_step,
    )

    module_strip_flag = "INSTALL_MOD_STRIP="
    if ctx.attr.strip_modules:
        module_strip_flag += "1"

    # Build the command for the main action.
    command = ctx.attr.config[KernelEnvInfo].setup
    command += """
           {cache_dir_cmd}
           {kbuild_mixed_tree_cmd}
         # Actual kernel build
           {interceptor_command_prefix} make -C ${{KERNEL_DIR}} ${{TOOL_ARGS}} O=${{OUT_DIR}} ${{MAKE_GOALS}}
         # Set variables and create dirs for modules
           mkdir -p {modules_staging_dir}
         # Install modules
           make -C ${{KERNEL_DIR}} ${{TOOL_ARGS}} DEPMOD=true O=${{OUT_DIR}} {module_strip_flag} INSTALL_MOD_PATH=$(realpath {modules_staging_dir}) modules_install
         # Archive headers in OUT_DIR
           find ${{OUT_DIR}} -name *.h -print0                          \
               | tar czf {out_dir_kernel_headers_tar}                   \
                       --absolute-names                                 \
                       --dereference                                    \
                       --transform "s,.*$OUT_DIR,,"                     \
                       --transform "s,^/,,"                             \
                       --null -T -
         # Grab outputs. If unable to find from OUT_DIR, look at KBUILD_MIXED_TREE as well.
           {search_and_cp_output} --srcdir ${{OUT_DIR}} {kbuild_mixed_tree_arg} {dtstree_arg} --dstdir {ruledir} {all_output_names_minus_modules}
         # Archive modules_staging_dir
           tar czf {modules_staging_archive_self} -C {modules_staging_dir} .
         # Grab *.symtypes
           {grab_symtypes_cmd}
         # Grab in-tree modules
           {grab_intree_modules_cmd}
         # Grab unstripped in-tree modules
           {grab_unstripped_intree_modules_cmd}
         # Check if there are remaining *.ko files
           remaining_ko_files=$({check_declared_output_list} \\
                --declared $(cat {all_module_names_file} {base_kernel_all_module_names_file_path}) \\
                --actual $(cd {modules_staging_dir}/lib/modules/*/kernel && find . -type f -name '*.ko' | sed 's:^[.]/::'))
           if [[ ${{remaining_ko_files}} ]]; then
             echo "ERROR: The following kernel modules are built but not copied. Add these lines to the module_outs attribute of {label}:" >&2
             for ko in ${{remaining_ko_files}}; do
               echo '    "'"${{ko}}"'",' >&2
             done
             echo "Alternatively, install buildozer and execute:" >&2
             echo "  $ buildozer 'add module_outs ${{remaining_ko_files}}' {label}" >&2
             echo "See https://github.com/bazelbuild/buildtools/blob/master/buildozer/README.md for reference" >&2
             exit 1
           fi
         # Clean up staging directories
           rm -rf {modules_staging_dir}
         """.format(
        cache_dir_cmd = cache_dir_step.cmd,
        kbuild_mixed_tree_cmd = kbuild_mixed_tree_ret.cmd,
        check_declared_output_list = ctx.file._check_declared_output_list.path,
        search_and_cp_output = ctx.file._search_and_cp_output.path,
        kbuild_mixed_tree_arg = kbuild_mixed_tree_ret.arg,
        dtstree_arg = "--srcdir ${OUT_DIR}/${dtstree}",
        ruledir = ruledir.path,
        all_output_names_minus_modules = " ".join(all_output_names.non_modules),
        grab_intree_modules_cmd = grab_intree_modules_step.cmd,
        grab_unstripped_intree_modules_cmd = grab_unstripped_modules_step.cmd,
        grab_symtypes_cmd = grab_symtypes_step.cmd,
        all_module_names_file = all_module_names_file.path,
        base_kernel_all_module_names_file_path = _path_or_empty(base_kernel_all_module_names_file),
        modules_staging_dir = modules_staging_dir,
        modules_staging_archive_self = modules_staging_archive_self.path,
        module_strip_flag = module_strip_flag,
        out_dir_kernel_headers_tar = out_dir_kernel_headers_tar.path,
        interceptor_command_prefix = interceptor_step.command_prefix,
        label = ctx.label,
    )

    # all inputs that |command| needs
    transitive_inputs = [target.files for target in ctx.attr.srcs]
    transitive_inputs += [target.files for target in ctx.attr.deps]
    inputs = [
        all_module_names_file,
    ]
    if base_kernel_all_module_names_file:
        inputs.append(base_kernel_all_module_names_file)
    inputs += check_toolchain_outs
    inputs += kbuild_mixed_tree_ret.outputs
    for step in steps:
        inputs += step.inputs

    # All tools that |command| needs
    tools = [
        ctx.file._search_and_cp_output,
        ctx.file._check_declared_output_list,
    ]
    tools += ctx.attr.config[KernelEnvInfo].dependencies
    for step in steps:
        tools += step.tools

    # all outputs that |command| generates
    command_outputs = [
        ruledir,
        modules_staging_archive_self,
        out_dir_kernel_headers_tar,
    ]
    for d in all_output_files.values():
        command_outputs += d.values()
    for step in steps:
        command_outputs += step.outputs

    debug.print_scripts(ctx, command)
    ctx.actions.run_shell(
        mnemonic = "KernelBuild",
        inputs = depset(_uniq(inputs), transitive = transitive_inputs),
        outputs = command_outputs,
        tools = _uniq(tools),
        progress_message = "Building kernel %s" % ctx.attr.name,
        command = command,
    )

    return struct(
        all_output_files = all_output_files,
        out_dir_kernel_headers_tar = out_dir_kernel_headers_tar,
        interceptor_output = interceptor_step.output_file,
        modules_staging_archive_self = modules_staging_archive_self,
        unstripped_dir = grab_unstripped_modules_step.unstripped_dir,
        ruledir = ruledir,
    )

def _create_infos(
        ctx,
        kbuild_mixed_tree_ret,
        all_module_names_file,
        main_action_ret,
        modules_staging_archive,
        toolchain_version_out,
        kmi_strict_mode_out):
    """Creates and returns a list of provided infos that the `kernel_build` target should return.

    Args:
        ctx: ctx
        kbuild_mixed_tree_ret: from `_create_kbuild_mixed_tree`
        all_module_names_file: A file containing all module names
        main_action_ret: from `_build_main_action`
        modules_staging_archive: from `_repack_modules_staging_archive`
        toolchain_version_out: from `_kernel_build_dump_toolchain_version`
        kmi_strict_mode_out: from `_kmi_symbol_list_strict_mode`
    """

    all_output_files = main_action_ret.all_output_files

    # Only outs and internal_outs are needed. But for simplicity, copy the full {ruledir}
    # which includes module_outs and implicit_outs too.
    env_info_dependencies = []
    env_info_dependencies += ctx.attr.config[KernelEnvInfo].dependencies
    for d in all_output_files.values():
        env_info_dependencies += d.values()
    env_info_dependencies += kbuild_mixed_tree_ret.outputs
    env_info_setup = ctx.attr.config[KernelEnvInfo].setup + """
         # Restore kernel build outputs
           cp -R {ruledir}/* ${{OUT_DIR}}
           """.format(ruledir = main_action_ret.ruledir.path)
    env_info_setup += kbuild_mixed_tree_ret.cmd
    env_info = KernelEnvInfo(
        dependencies = env_info_dependencies,
        setup = env_info_setup,
    )

    kernel_build_info = KernelBuildInfo(
        out_dir_kernel_headers_tar = main_action_ret.out_dir_kernel_headers_tar,
        outs = all_output_files["outs"].values(),
        base_kernel_files = kbuild_mixed_tree_ret.base_kernel_files,
        interceptor_output = main_action_ret.interceptor_output,
        kernel_release = all_output_files["internal_outs"]["include/config/kernel.release"],
    )

    module_srcs = kernel_utils.filter_module_srcs(ctx.files.srcs)

    kernel_build_module_info = KernelBuildExtModuleInfo(
        modules_staging_archive = modules_staging_archive,
        module_hdrs = module_srcs.module_hdrs,
        module_scripts = module_srcs.module_scripts,
        modules_prepare_setup = ctx.attr.modules_prepare[KernelEnvInfo].setup,
        modules_prepare_deps = ctx.attr.modules_prepare[KernelEnvInfo].dependencies,
        collect_unstripped_modules = ctx.attr.collect_unstripped_modules,
        strip_modules = ctx.attr.strip_modules,
    )

    kernel_uapi_depsets = []
    if ctx.attr.base_kernel:
        kernel_uapi_depsets.append(ctx.attr.base_kernel[KernelBuildUapiInfo].kernel_uapi_headers)
    kernel_uapi_depsets.append(ctx.attr.kernel_uapi_headers.files)
    kernel_build_uapi_info = KernelBuildUapiInfo(
        kernel_uapi_headers = depset(transitive = kernel_uapi_depsets, order = "postorder"),
    )

    kernel_build_abi_info = KernelBuildAbiInfo(
        trim_nonlisted_kmi = ctx.attr.trim_nonlisted_kmi,
        combined_abi_symbollist = ctx.file.combined_abi_symbollist,
        module_outs_file = all_module_names_file,
        modules_staging_archive = modules_staging_archive,
    )

    kernel_unstripped_modules_info = KernelUnstrippedModulesInfo(
        base_kernel = ctx.attr.base_kernel,
        directory = main_action_ret.unstripped_dir,
    )

    in_tree_modules_info = KernelBuildInTreeModulesInfo(
        module_outs_file = all_module_names_file,
    )

    images_info = KernelImagesInfo(base_kernel = ctx.attr.base_kernel)

    output_group_kwargs = {}
    for d in all_output_files.values():
        output_group_kwargs.update({name: depset([file]) for name, file in d.items()})
    output_group_kwargs["modules_staging_archive"] = depset([modules_staging_archive])
    output_group_kwargs[MODULE_OUTS_FILE_OUTPUT_GROUP] = depset([all_module_names_file])
    output_group_kwargs[TOOLCHAIN_VERSION_FILENAME] = depset([toolchain_version_out])
    output_group_info = OutputGroupInfo(**output_group_kwargs)

    kbuild_mixed_tree_files = all_output_files["outs"].values() + all_output_files["module_outs"].values()
    kbuild_mixed_tree_info = KernelBuildMixedTreeInfo(
        files = depset(kbuild_mixed_tree_files),
    )

    default_info_files = all_output_files["outs"].values() + all_output_files["module_outs"].values()
    default_info_files.append(all_module_names_file)
    if kmi_strict_mode_out:
        default_info_files.append(kmi_strict_mode_out)
    default_info = DefaultInfo(
        files = depset(default_info_files),
        # For kernel_build_test
        runfiles = ctx.runfiles(files = default_info_files),
    )

    return [
        env_info,
        kbuild_mixed_tree_info,
        kernel_build_info,
        kernel_build_module_info,
        kernel_build_uapi_info,
        kernel_build_abi_info,
        kernel_unstripped_modules_info,
        in_tree_modules_info,
        images_info,
        output_group_info,
        default_info,
    ]

def _kernel_build_impl(ctx):
    kbuild_mixed_tree_ret = _create_kbuild_mixed_tree(ctx)
    check_toolchain_outs = _kernel_build_check_toolchain(ctx)

    all_output_names = _split_out_attrs(ctx)

    # A file containing all module names
    all_module_names_file = _write_module_names_to_file(
        ctx,
        ctx.label.name + MODULE_OUTS_FILE_SUFFIX,
        all_output_names.modules,
    )

    # A file containing the basenames of the modules
    all_module_basenames_file = _write_module_names_to_file(
        ctx,
        "all_module_basenames.txt",
        [paths.basename(filename) for filename in all_output_names.modules],
    )

    main_action_ret = _build_main_action(
        ctx = ctx,
        kbuild_mixed_tree_ret = kbuild_mixed_tree_ret,
        all_output_names = all_output_names,
        all_module_names_file = all_module_names_file,
        all_module_basenames_file = all_module_basenames_file,
        check_toolchain_outs = check_toolchain_outs,
    )

    modules_staging_archive = _repack_modules_staging_archive(
        ctx = ctx,
        modules_staging_archive_self = main_action_ret.modules_staging_archive_self,
        all_module_basenames_file = all_module_basenames_file,
    )

    toolchain_version_out = _kernel_build_dump_toolchain_version(ctx)

    kmi_strict_mode_out = _kmi_symbol_list_strict_mode(
        ctx,
        main_action_ret.all_output_files,
        all_module_names_file,
    )

    infos = _create_infos(
        ctx = ctx,
        kbuild_mixed_tree_ret = kbuild_mixed_tree_ret,
        all_module_names_file = all_module_names_file,
        main_action_ret = main_action_ret,
        modules_staging_archive = modules_staging_archive,
        toolchain_version_out = toolchain_version_out,
        kmi_strict_mode_out = kmi_strict_mode_out,
    )

    return infos

_kernel_build = rule(
    implementation = _kernel_build_impl,
    doc = "Defines a kernel build target.",
    attrs = {
        "config": attr.label(
            mandatory = True,
            providers = [KernelEnvInfo, KernelEnvAttrInfo],
            aspects = [kernel_toolchain_aspect],
            doc = "the kernel_config target",
        ),
        "srcs": attr.label_list(mandatory = True, doc = "kernel sources", allow_files = True),
        "outs": attr.string_list(),
        "module_outs": attr.string_list(doc = "output *.ko files"),
        "internal_outs": attr.string_list(doc = "Like `outs`, but not in dist"),
        "module_implicit_outs": attr.string_list(doc = "Like `module_outs`, but not in dist"),
        "implicit_outs": attr.string_list(doc = "Like `outs`, but not in dist"),
        "_check_declared_output_list": attr.label(
            allow_single_file = True,
            default = Label("//build/kernel/kleaf:check_declared_output_list.py"),
        ),
        "_search_and_cp_output": attr.label(
            allow_single_file = True,
            default = Label("//build/kernel/kleaf:search_and_cp_output.py"),
            doc = "label referring to the script to process outputs",
        ),
        "deps": attr.label_list(
            allow_files = True,
        ),
        "base_kernel": attr.label(
            aspects = [kernel_toolchain_aspect],
            providers = [KernelBuildInTreeModulesInfo, KernelBuildMixedTreeInfo],
        ),
        "base_kernel_for_module_outs": attr.label(
            providers = [KernelBuildInTreeModulesInfo],
            doc = "If set, use the `module_outs` and `module_implicit_outs` of this label as an allowlist for modules in the staging directory. Otherwise use `base_kernel`.",
        ),
        "kmi_symbol_list_strict_mode": attr.bool(),
        "raw_kmi_symbol_list": attr.label(
            doc = "Label to abi_symbollist.raw.",
            allow_single_file = True,
        ),
        "collect_unstripped_modules": attr.bool(),
        "enable_interceptor": attr.bool(),
        "_compare_to_symbol_list": attr.label(default = "//build/kernel:abi/compare_to_symbol_list", allow_single_file = True),
        "_hermetic_tools": attr.label(default = "//build/kernel:hermetic-tools", providers = [HermeticToolsInfo]),
        "_debug_print_scripts": attr.label(default = "//build/kernel/kleaf:debug_print_scripts"),
        "_config_is_local": attr.label(default = "//build/kernel/kleaf:config_local"),
        "_cache_dir": attr.label(default = "//build/kernel/kleaf:cache_dir"),
        # Though these rules are unrelated to the `_kernel_build` rule, they are added as fake
        # dependencies so KernelBuildExtModuleInfo and KernelBuildUapiInfo works.
        # There are no real dependencies. Bazel does not build these targets before building the
        # `_kernel_build` target.
        "modules_prepare": attr.label(),
        "kernel_uapi_headers": attr.label(),
        "trim_nonlisted_kmi": attr.bool(),
        "combined_abi_symbollist": attr.label(allow_single_file = True, doc = "The **combined** `abi_symbollist` file, consist of `kmi_symbol_list` and `additional_kmi_symbol_lists`."),
        "strip_modules": attr.bool(default = False, doc = "if set, debug information won't be kept for distributed modules.  Note, modules will still be stripped when copied into the ramdisk."),
    },
)

def _kernel_build_check_toolchain(ctx):
    """Checks toolchain_version is the same as base_kernel.

    Returns:
        A list, which may or may not contain a [File](https://bazel.build/rules/lib/File) that
        checks toolchain version at execution phase when it is built. If it is an empty list,
        no checks need to be performed at execution phase.
    """

    base_kernel = ctx.attr.base_kernel
    if not base_kernel:
        return []

    this_toolchain = ctx.attr.config[KernelToolchainInfo].toolchain_version
    base_toolchain = utils.getoptattr(base_kernel[KernelToolchainInfo], "toolchain_version")
    base_toolchain_file = utils.getoptattr(base_kernel[KernelToolchainInfo], "toolchain_version_file")

    if base_toolchain == None and base_toolchain_file == None:
        print(("\nWARNING: {this_label}: No check is performed between the toolchain " +
               "version of the base build ({base_kernel}) and the toolchain version of " +
               "{this_name} ({this_toolchain}), because the toolchain version of {base_kernel} " +
               "is unknown.").format(
            this_label = ctx.label,
            base_kernel = base_kernel.label,
            this_name = ctx.label.name,
            this_toolchain = this_toolchain,
        ))
        return []

    if base_toolchain != None and this_toolchain != base_toolchain:
        fail("""{this_label}:

ERROR: `toolchain_version` is "{this_toolchain}" for "{this_label}", but
       `toolchain_version` is "{base_toolchain}" for "{base_kernel}" (`base_kernel`).
       They must use the same `toolchain_version`.

       Fix by setting `toolchain_version` of "{this_label}"
       to be the one used by "{base_kernel}".
       If "{base_kernel}" does not set `toolchain_version` explicitly, do not set
       `toolchain_version` for "{this_label}" either.
""".format(
            this_label = ctx.label,
            this_toolchain = this_toolchain,
            base_kernel = base_kernel.label,
            base_toolchain = base_toolchain,
        ))

    if base_toolchain_file != None:
        out = ctx.actions.declare_file("{}_toolchain_version/toolchain_version_checked".format(ctx.label.name))
        base_toolchain = "$(cat {})".format(base_toolchain_file.path)
        msg = """ERROR: toolchain_version is {this_toolchain} for {this_label}, but
       toolchain_version is {base_toolchain} for {base_kernel} (base_kernel).
       They must use the same toolchain_version.

       Fix by setting toolchain_version of {this_label} to be {base_toolchain}.
""".format(
            this_label = ctx.label,
            this_toolchain = this_toolchain,
            base_kernel = base_kernel.label,
            base_toolchain = base_toolchain,
        )
        command = ctx.attr._hermetic_tools[HermeticToolsInfo].setup + """
                # Check toolchain_version against base kernel
                  if ! diff <(cat {base_toolchain_file}) <(echo "{this_toolchain}") > /dev/null; then
                    echo "{msg}" >&2
                    exit 1
                  fi
                  touch {out}
        """.format(
            base_toolchain_file = base_toolchain_file.path,
            this_toolchain = this_toolchain,
            msg = msg,
            out = out.path,
        )

        debug.print_scripts(ctx, command, what = "check_toolchain")
        ctx.actions.run_shell(
            mnemonic = "KernelBuildCheckToolchain",
            inputs = [base_toolchain_file] + ctx.attr._hermetic_tools[HermeticToolsInfo].deps,
            outputs = [out],
            command = command,
            progress_message = "Checking toolchain version against base kernel {}".format(ctx.label),
        )
        return [out]
    return []

def _kernel_build_dump_toolchain_version(ctx):
    this_toolchain = ctx.attr.config[KernelToolchainInfo].toolchain_version
    out = ctx.actions.declare_file("{}_toolchain_version/{}".format(ctx.attr.name, TOOLCHAIN_VERSION_FILENAME))
    ctx.actions.write(
        output = out,
        content = this_toolchain + "\n",
    )
    return out

def _kmi_symbol_list_strict_mode(ctx, all_output_files, all_module_names_file):
    """Run for `KMI_SYMBOL_LIST_STRICT_MODE`.
    """
    if not ctx.attr.kmi_symbol_list_strict_mode:
        return None
    if not ctx.file.raw_kmi_symbol_list:
        fail("{}: kmi_symbol_list_strict_mode requires kmi_symbol_list or additional_kmi_symbol_lists.")

    vmlinux = all_output_files["outs"].get("vmlinux")
    if not vmlinux:
        fail("{}: with kmi_symbol_list_strict_mode, outs does not contain vmlinux")
    module_symvers = all_output_files["internal_outs"].get("Module.symvers")
    if not module_symvers:
        fail("{}: with kmi_symbol_list_strict_mode, outs does not contain module_symvers")

    inputs = [
        module_symvers,
        ctx.file.raw_kmi_symbol_list,
        all_module_names_file,
    ]
    inputs += ctx.attr.config[KernelEnvInfo].dependencies
    inputs += ctx.files._compare_to_symbol_list

    out = ctx.actions.declare_file("{}_kmi_strict_out/kmi_symbol_list_strict_mode_checked".format(ctx.attr.name))
    command = ctx.attr.config[KernelEnvInfo].setup + """
        KMI_STRICT_MODE_OBJECTS="{vmlinux_base} $(cat {all_module_names_file} | sed 's/\\.ko$//')" {compare_to_symbol_list} {module_symvers} {raw_kmi_symbol_list}
        touch {out}
    """.format(
        vmlinux_base = vmlinux.basename,  # A fancy way of saying "vmlinux"
        all_module_names_file = all_module_names_file.path,
        compare_to_symbol_list = ctx.file._compare_to_symbol_list.path,
        module_symvers = module_symvers.path,
        raw_kmi_symbol_list = ctx.file.raw_kmi_symbol_list.path,
        out = out.path,
    )
    debug.print_scripts(ctx, command, what = "kmi_symbol_list_strict_mode")
    ctx.actions.run_shell(
        mnemonic = "KernelBuildKmiSymbolListStrictMode",
        inputs = inputs,
        outputs = [out],
        command = command,
        progress_message = "Checking for kmi_symbol_list_strict_mode {}".format(ctx.label),
    )
    return out

def _repack_modules_staging_archive(
        ctx,
        modules_staging_archive_self,
        all_module_basenames_file):
    """Repackages `modules_staging_archive` to contain kernel modules from `base_kernel` as well.

    Args:
        ctx: ctx
        modules_staging_archive_self: The `modules_staging_archive` from `make`
            in `_build_main_action`.
    """
    if not ctx.attr.base_kernel:
        # No need to repack.
        if not modules_staging_archive_self.basename == MODULES_STAGING_ARCHIVE:
            fail("\nFATAL: {}: modules_staging_archive_self.basename == {}, but not {}".format(
                ctx.label,
                modules_staging_archive_self.basename,
                MODULES_STAGING_ARCHIVE,
            ))
        return modules_staging_archive_self

    modules_staging_archive = ctx.actions.declare_file(
        "{}_module_staging_archive/{}".format(ctx.label.name, MODULES_STAGING_ARCHIVE),
    )

    # Re-package module_staging_dir to also include the one from base_kernel.
    # Pick ko files only from base_kernel, while keeping all depmod files from self.
    modules_staging_dir = modules_staging_archive.dirname + "/staging"
    cmd = ctx.attr._hermetic_tools[HermeticToolsInfo].setup + """
        mkdir -p {modules_staging_dir}
        tar xf {self_archive} -C {modules_staging_dir}

        # Filter out device-customized modules that has the same name as GKI modules
        base_modules=$(tar tf {base_archive} | grep '[.]ko$' || true)
        for module in $(cat {all_module_basenames_file}); do
          base_modules=$(echo "${{base_modules}}" | grep -v "${{module}}"'$' || true)
        done

        if [[ -n "${{base_modules}}" ]]; then
            tar xf {base_archive} -C {modules_staging_dir} ${{base_modules}}
        fi
        tar czf {out_archive} -C  {modules_staging_dir} .
        rm -rf {modules_staging_dir}
    """.format(
        modules_staging_dir = modules_staging_dir,
        self_archive = modules_staging_archive_self.path,
        base_archive = ctx.attr.base_kernel[KernelBuildExtModuleInfo].modules_staging_archive.path,
        out_archive = modules_staging_archive.path,
        all_module_basenames_file = all_module_basenames_file.path,
    )
    debug.print_scripts(ctx, cmd, what = "repackage_module_staging_archive")
    ctx.actions.run_shell(
        mnemonic = "KernelBuildModuleStagingArchive",
        inputs = [
            modules_staging_archive_self,
            ctx.attr.base_kernel[KernelBuildExtModuleInfo].modules_staging_archive,
            all_module_basenames_file,
        ],
        outputs = [modules_staging_archive],
        tools = ctx.attr._hermetic_tools[HermeticToolsInfo].deps,
        progress_message = "Repackaging module_staging_archive {}".format(ctx.label),
        command = cmd,
    )
    return modules_staging_archive
