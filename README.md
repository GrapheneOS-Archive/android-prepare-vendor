## Introduction

This project is designed to automate the extraction of proprietary proprietary executables,
DSOs, APKs, JARs and other device specific items, such as XML declarations and
device props. Google does release proprietary vendor binaries however these are
incomplete and is missing other items such as symbolic links, various libraries
and so on that would otherwise be on the `/system` and `/product` partitions for example.

Modern Android devices have their bytecode (APKs, JARs) pre-optimized to reduce
boot time and their original `classes.dex` are stripped to reduce disk size. 
As such, these missing prebuilt components need to be repaired/de-optimized
prior to being included, since the AOSP build system is not capable of importing
pre-optimized bytecode modules as part of the makefile tree.

This is a continuation of the https://github.com/anestisb/android-prepare-vendor project.

## Requirements

https://grapheneos.org/build#build-dependencies

## Usage

https://grapheneos.org/build#extracting-vendor-files-for-pixel-devices
