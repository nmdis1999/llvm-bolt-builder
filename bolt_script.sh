#! /bin/sh

set -eof

# Declare variables
home=$HOME
dirc=$1

if [ -z "$dirc" ]; then
        dirc="bolt"
fi

path=$home/$dirc

if [ ! -d $path ]; then
        mkdir $path
        cd $path

        # Clone the llvm-project repository
        git clone https://github.com/llvm/llvm-project.git

        # Create a build directory and navigate to it
        mkdir build
        cd build

        # Run cmake and ninja
        cmake -G Ninja ../llvm-project/llvm -DLLVM_TARGETS_TO_BUILD="X86;AArch64" -DCMAKE_BUILD_TYPE=Release -DLLVM_ENABLE_ASSERTIONS=ON -DLLVM_ENABLE_PROJECTS="bolt"
        ninja bolt install
fi

export PATH=$path/build/bin:$PATH

# Clang build starts
TOPLEV=~/bolt/clang
mkdir $ {TOPLEV}
cd $ {TOPLEV}
git clone https://github.com/llvm/llvm-project.git

#Add a line to check if GCC is installed on the system
if command -v gcc >/dev/null; then
        echo "GCC is installed, proceeding with the build"
else
        echo "GCC is not installed, please install GCC before proceeding"
        exit 1
fi

# Build stage1 clang from default gcc
if [ ! -d ${TOPLEV} ]; then
        mkdir ${TOPLEV}/stage1
        cd $ {TOPLEV}/stage1
        cmake -G Ninja $ {TOPLEV}/llvm-project/llvm -DLLVM_TARGETS_TO_BUILD=X86 \
                -DCMAKE_BUILD_TYPE=Release \
                -DCMAKE_C_COMPILER=gcc -DCMAKE_CXX_COMPILER=g++ -DCMAKE_ASM_COMPILER=gcc \
                -DLLVM_ENABLE_PROJECTS="clang;lld" \
                -DLLVM_ENABLE_RUNTIMES="compiler-rt" \
                -DCOMPILER_RT_BUILD_SANITIZERS=OFF -DCOMPILER_RT_BUILD_XRAY=OFF \
                -DCOMPILER_RT_BUILD_LIBFUZZER=OFF \
                -DCMAKE_INSTALL_PREFIX=$ {TOPLEV}/stage1/install
        ninja install
fi

# Build stage2 compiler with Instrumentation
if [ ! -d ${TOPLEV}/stage2-prof-gen]; then
        mkdir ${TOPLEV}/stage2-prof-gen
        cd ${TOPLEV}/stage2-prof-gen
        CPATH=$ {TOPLEV}/stage1/install/bin/
        cmake -G Ninja $ {TOPLEV}/llvm-project/llvm -DLLVM_TARGETS_TO_BUILD=X86 \
                -DCMAKE_BUILD_TYPE=Release \
                -DCMAKE_C_COMPILER=$CPATH/clang -DCMAKE_CXX_COMPILER=$CPATH/clang++ \
                -DLLVM_ENABLE_PROJECTS="clang;lld" \
                -DLLVM_USE_LINKER=lld -DLLVM_BUILD_INSTRUMENTED=ON \
                -DCMAKE_INSTALL_PREFIX=$ {TOPLEV}/stage2-prof-gen/install
        ninja install
fi

# Generating profile for PGO
if [ ! -d ${TOPLEV}/stage3-train ]; then
        mkdir ${TOPLEV}/stage3-train
        cd $ {TOPLEV}/stage3-train
        CPATH=$ {TOPLEV}/stage2-prof-gen/install/bin
        cmake -G Ninja $ {TOPLEV}/llvm-project/llvm -DLLVM_TARGETS_TO_BUILD=X86 \
                -DCMAKE_BUILD_TYPE=Release \
                -DCMAKE_C_COMPILER=$CPATH/clang -DCMAKE_CXX_COMPILER=$CPATH/clang++ \
                -DLLVM_ENABLE_PROJECTS="clang" \
                -DLLVM_USE_LINKER=lld -DCMAKE_INSTALL_PREFIX=$ {TOPLEV}/stage3-train/install
        ninja clang
fi

# Merging profile before passing to Clang
cd $ {TOPLEV}/stage2-prof-gen/profiles
$ {TOPLEV}/stage1/install/bin/llvm-profdata merge -output=clang.profdata *

# Building Clang with PGO and LTO
if [ ! -d ${TOPLEV}/stage2-prof-use-lto ]; then
        mkdir ${TOPLEV}/stage2-prof-use-lto
        cd $ {TOPLEV}/stage2-prof-use-lto
        CPATH=$ {TOPLEV}/stage1/install/bin/
        export LDFLAGS="-Wl,-q"
        cmake -G Ninja $ {TOPLEV}/llvm-project/llvm -DLLVM_TARGETS_TO_BUILD=X86 \
                -DCMAKE_BUILD_TYPE=Release \
                -DCMAKE_C_COMPILER=$CPATH/clang -DCMAKE_CXX_COMPILER=$CPATH/clang++ \
                -DLLVM_ENABLE_PROJECTS="clang;lld" \
                -DLLVM_ENABLE_LTO=Full \
                -DLLVM_PROFDATA_FILE=$ {TOPLEV}/stage2-prof-gen/profiles/clang.profdata \
                -DLLVM_USE_LINKER=lld \
                -DCMAKE_INSTALL_PREFIX=${TOPLEV}/stage2-prof-use-lto/install
        ninja install
fi

# Optimising Clang with BOLT
if [ ! -d ${TOPLEV}/stage3 ]; then
        mkdir $ {TOPLEV}/stage3
        cd $ {TOPLEV}/stage3
        CPATH=$ {TOPLEV}/stage2-prof-use-lto/install/bin/
        cmake -G Ninja $ {TOPLEV}/llvm-project/llvm -DLLVM_ENABLE_PROJECTS=clang \
                -DLLVM_TARGETS_TO_BUILD=X86 -DCMAKE_BUILD_TYPE=Release \
                -DCMAKE_C_COMPILER=$CPATH/clang -DCMAKE_CXX_COMPILER=$CPATH/clang++ \
                -DLLVM_USE_LINKER=lld -DCMAKE_INSTALL_PREFIX=$ {TOPLEV}/stage3/install
        perf record -e cycles: u -j any,u -- ninja clang
fi

# Converting perf.data to BOLT format where x is the clang version
perf2bolt $CPATH/clang-x -p perf.data -o clang-x.fdata

# Using the generated profile to get optimized binary
llvm-bolt $CPATH/clang-7 -o $CPATH/clang-7.bolt
