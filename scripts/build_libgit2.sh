#! /usr/bin/env bash

install_dir=$1
branch=$2

git clone --depth=1 -b $branch https://github.com/libgit2/libgit2.git

mkdir libgit2/build
cd libgit2/build

cmake .. -DCMAKE_INSTALL_PREFIX=$install_dir -DBUILD_CLAR=OFF
cmake --build . --target install
