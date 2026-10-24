# =============================================================================
# odd — Makefile
# -----------------------------------------------------------------------------
# 两条互不相干的使用场景，别混淆：
#
#   A. 本地开发（默认目标仍是 build）
#        make / make build / make test / make diff / make verify / make guard
#      实际逻辑都在脚本里（build.sh / test.sh / verify.sh / tests/run.sh），
#      Make 只做入口别名。理由：脚本能被单独调用、能被 CI 直接执行，
#      而 Make 的隐含规则会让人误以为存在另一条构建路径。
#
#   B. 交叉编译发布
#        make all    # 全部平台 → dist/odd-<平台>
#        make main   # 五大主流
#        make host   # 只构建本机平台
#        make dist-check   # 用 file(1) 核对每个产物的真实格式
#        make list   # 列出平台表
#
# 为什么分两条路（沿用 ../xrep 的结论，本机实证）：
#   Odin 的原生链接器在本机只能链接「本机平台」和 darwin_amd64（走 macOS SDK），
#   对 linux_* / windows_* 会直接报
#   "Linking for cross compilation for this platform is not yet supported"。
#   所以：
#     darwin_*  → odin 原生链接（-linker:lld），不需要 zig
#     其余平台  → odin 只编译（-build-mode:obj），再用 `zig cc` 链接
#   zig 自带各平台的 libc / 导入库，无需 sysroot 或 Windows SDK。
#
# 前置：odin（dev-2026-10+）；zig（仅非 darwin 目标需要，已验证 0.17.0）
#
# 与 xrep 的一处刻意差异：xrep 把「核对产物格式」叫 check，本仓库的 check
# 早在交叉编译之前就被占用了（= odin check 只做类型检查），所以这里叫
# dist-check。名字让位于既有习惯。
# =============================================================================

SHELL := /bin/sh

# ---- 本地开发相关 ----------------------------------------------------------

BIN  := bin/odd
GX   ?= ../gx/bin/gx
WORK ?= /tmp/odd-tests

.PHONY: build test diff verify guard fmt check clean help

.DEFAULT_GOAL := build

build:
	./build.sh

test:
	./test.sh

diff: build
	./tests/run.sh $(BIN)

guard:
	./tools/guard.sh

verify:
	./verify.sh

# odinfmt 就地格式化（会改动工作区，先看一眼 git diff 再提交）
fmt:
	odinfmt -w .

# 只做类型检查不产物：比 build 快，适合编辑循环
check:
	ODIN_CC=/usr/bin/clang odin check . -collection:odd=. -no-entry-point

clean:
	rm -rf bin
	rm -rf "$(WORK)"

help:
	@sed -n 's/^#   make //p' Makefile

# =============================================================================
# 以下为交叉编译
# =============================================================================

ODIN  ?= odin
ZIG   ?= zig
# odin 优化级别：none|minimal|size|speed
# 注意：这些赋值不要写行内注释——GNU make 会把 `#` 前的空格一并算进变量值。
OPT   ?= size
DIST  ?= dist
BUILD ?= .build
# darwin 原生链接使用的链接器
LINKER ?= lld

# 源码按职责拆成子目录包（lib/search/engine/app），Odin 的 import 路径相对
# 源文件所在目录解析，兄弟包必须靠 collection 互相引用（见 ADR 0001）。
# 注意：Makefile 里用绝对路径 $(CURDIR)，避免 `make -C` 时解析错位。
COLLECTION ?= odd=$(CURDIR)
ODIN_FLAGS ?= -collection:$(COLLECTION)

# zig cc 的编译选项。-O2 是链接期优化等级，与 odin 的 -o:$(OPT) 无关。
ZIG_CFLAGS ?= -O2

# 本机 PATH 里的 clang 可能被 Android NDK 抢占，导致链接报 unknown file type。
# 与 build.sh 保持一致：显式指向系统 Apple clang。
ODIN_CC ?= $(shell test -x /usr/bin/clang && echo /usr/bin/clang)
export ODIN_CC

# Windows 目标：Odin 要求给出 -windows-sdk-root，但走 zig cc 链接时并不真的
# 需要 SDK 内容，给一个空目录即可通过该检查（zig 自带 mingw 导入库）。
WINSDK ?= $(BUILD)/winsdk

VERSION  := $(shell grep -m1 'ODD_VERSION ::' lib/base.odin | cut -d'"' -f2)
ZIG_PATH := $(shell command -v $(ZIG) 2>/dev/null)

# ---- 平台表生成 ------------------------------------------------------------
#
# $(call DEFINE_TARGET, 短名, odin-target, zig-triple, 扩展名,
#                       额外链接参数, native|cross, 需要 _fltused)
#
# 第 7 参说明：Windows 的 COFF 目标文件会引用两个 mingw 没提供的符号：
#   BCryptGenRandom —— Odin runtime 的随机源，由 bcrypt 导入库提供（-lbcrypt）
#   _fltused        —— MSVC 的浮点使用标记，mingw 未定义；这里自行提供一个
#                      空符号垫片（见下方 fltused 规则）
define DEFINE_TARGET
TARGETS += $(1)
.PHONY: $(1)
ifeq ($(7),yes)
$(1): $(BUILD)/fltused-$(1).o
$(BUILD)/fltused-$(1).o:
	@mkdir -p $(BUILD)
	@printf 'int _fltused = 0x9875;\n' > $(BUILD)/fltused-$(1).c
	$(ZIG) cc -target $(3) -c $(BUILD)/fltused-$(1).c -o $$@
endif
$(1):
	@mkdir -p $(DIST) $(BUILD) $(WINSDK)
ifeq ($(6),native)
	@echo "==> $(1)	[odin 原生链接]"
	$(ODIN) build . $(ODIN_FLAGS) -target:$(2) -o:$(OPT) -linker:$(LINKER) -out:$(DIST)/odd-$(1)$(4)
else
	@echo "==> $(1)	[obj -> $(ZIG) cc -target:$(3)]"
	@if [ -z "$(ZIG_PATH)" ]; then \
		echo "错误：构建 $(1) 需要 $(ZIG)，但未在 PATH 中找到。" >&2; \
		echo "      安装：brew install zig   （或改用 'make host' 只构建本机平台）" >&2; \
		exit 1; \
	fi
	$(ODIN) build . $(ODIN_FLAGS) -target:$(2) -build-mode:obj -o:$(OPT) -out:$(BUILD)/$(1).o \
		$(if $(findstring windows,$(2)),-windows-sdk-root:$(WINSDK),)
	$(ZIG) cc -target $(3) $(ZIG_CFLAGS) $(BUILD)/$(1).o $(5) -o $(DIST)/odd-$(1)$(4)
	@rm -f $(DIST)/odd-$(1).pdb   # lld-link 顺手生成的调试库，分发不需要
endif
endef

# --- 主流（Tier 1）---
$(eval $(call DEFINE_TARGET,darwin-arm64,darwin_arm64,,,,native,))
$(eval $(call DEFINE_TARGET,darwin-amd64,darwin_amd64,,,,native,))
$(eval $(call DEFINE_TARGET,linux-amd64,linux_amd64,x86_64-linux-gnu,,,cross,))
$(eval $(call DEFINE_TARGET,linux-arm64,linux_arm64,aarch64-linux-gnu,,,cross,))
$(eval $(call DEFINE_TARGET,windows-amd64,windows_amd64,x86_64-windows-gnu,.exe,$(BUILD)/fltused-windows-amd64.o -lbcrypt,cross,yes))

# --- 扩展（Tier 2）---
$(eval $(call DEFINE_TARGET,linux-386,linux_i386,x86-linux-gnu,,,cross,))
$(eval $(call DEFINE_TARGET,linux-arm,linux_arm32,arm-linux-gnueabihf,,,cross,))
$(eval $(call DEFINE_TARGET,linux-riscv64,linux_riscv64,riscv64-linux-gnu,,,cross,))
$(eval $(call DEFINE_TARGET,freebsd-amd64,freebsd_amd64,x86_64-freebsd-none,,,cross,))
$(eval $(call DEFINE_TARGET,freebsd-arm64,freebsd_arm64,aarch64-freebsd-none,,,cross,))

# --- Linux 静态变体（musl，不依赖目标机 glibc 版本）---
# 注意：zig 0.17 起 i386 的架构名是 x86，不是 i386。
$(eval $(call DEFINE_TARGET,linux-amd64-musl,linux_amd64,x86_64-linux-musl,,-static,cross,))
$(eval $(call DEFINE_TARGET,linux-arm64-musl,linux_arm64,aarch64-linux-musl,,-static,cross,))

MAIN_TARGETS  := darwin-arm64 darwin-amd64 linux-amd64 linux-arm64 windows-amd64
EXTRA_TARGETS := linux-386 linux-arm linux-riscv64 freebsd-amd64 freebsd-arm64
MUSL_TARGETS  := linux-amd64-musl linux-arm64-musl

# ---- 聚合目标 --------------------------------------------------------------

HOST_OS     := $(shell uname -s | tr '[:upper:]' '[:lower:]')
HOST_ARCH   := $(patsubst x86_64,amd64,$(shell uname -m))
HOST_TARGET := $(HOST_OS)-$(HOST_ARCH)

.PHONY: all main extra musl host universal dist-check list checksums distclean

all: $(MAIN_TARGETS) $(EXTRA_TARGETS)

main: $(MAIN_TARGETS)

extra: $(EXTRA_TARGETS)

musl: $(MUSL_TARGETS)

# 只构建当前机器平台。若本机平台不在表中（冷门组合），回退到普通 odin build。
host:
	@mkdir -p $(DIST)
	@if echo " $(TARGETS) " | grep -q " $(HOST_TARGET) "; then \
		$(MAKE) $(HOST_TARGET); \
	else \
		echo "==> host [$(HOST_TARGET) 不在平台表中，直接 odin build]"; \
		$(ODIN) build . $(ODIN_FLAGS) -o:$(OPT) -linker:$(LINKER) -out:$(DIST)/odd-$(HOST_TARGET); \
	fi

# macOS universal2：把 arm64 与 amd64 两个 Mach-O 合并为一个胖二进制。
universal: darwin-arm64 darwin-amd64
	@mkdir -p $(DIST)
	lipo -create -output $(DIST)/odd-darwin-universal \
		$(DIST)/odd-darwin-arm64 $(DIST)/odd-darwin-amd64
	@echo "==> darwin-universal	[lipo 合并]"

# 核对每个产物是不是真的目标格式（而非本机 Mach-O）
dist-check:
	@if [ ! -d $(DIST) ] || [ -z "$$(ls -A $(DIST) 2>/dev/null)" ]; then \
		echo "dist/ 为空，先运行 make all" >&2; exit 1; \
	fi
	@for f in $(DIST)/*; do printf '%-40s ' "$$(basename $$f)"; file -b "$$f"; done

list:
	@echo "平台短名              odin target        zig triple"
	@echo "--------------------  -----------------  -------------------------"
	@printf '%s\n' \
		"darwin-arm64          darwin_arm64       (odin 原生链接)" \
		"darwin-amd64          darwin_amd64       (odin 原生链接)" \
		"linux-amd64           linux_amd64        x86_64-linux-gnu" \
		"linux-arm64           linux_arm64        aarch64-linux-gnu" \
		"windows-amd64         windows_amd64      x86_64-windows-gnu" \
		"linux-386             linux_i386         x86-linux-gnu" \
		"linux-arm             linux_arm32        arm-linux-gnueabihf" \
		"linux-riscv64         linux_riscv64      riscv64-linux-gnu" \
		"freebsd-amd64         freebsd_amd64      x86_64-freebsd-none" \
		"freebsd-arm64         freebsd_arm64      aarch64-freebsd-none" \
		"linux-amd64-musl      linux_amd64        x86_64-linux-musl (静态)" \
		"linux-arm64-musl      linux_arm64        aarch64-linux-musl (静态)"

# 分发校验和（文件名带版本，避免与旧产物混淆）
checksums:
	@cd $(DIST) && shasum -a 256 odd-* > SHA256SUMS-$(VERSION).txt
	@echo "已生成 $(DIST)/SHA256SUMS-$(VERSION).txt"

distclean: clean
	rm -rf $(DIST) $(BUILD)
	rm -f odd
