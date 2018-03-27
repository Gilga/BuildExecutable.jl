# BuildExecutable
[![Build Status](https://travis-ci.org/Gilga/BuildExecutable.jl.svg?branch=master)](https://travis-ci.org/Gilga/BuildExecutable.jl)
[![Build status](https://ci.appveyor.com/api/projects/status/eoyxl4doixob24xc?svg=true)](https://ci.appveyor.com/project/Gilga/buildexecutable-jl)

Forked from [here](https://github.com/dhoegh/BuildExecutable.jl).

# Status
* ~~Works with 0.5.1~~ (deprecated, not tested anymore!)
* ~~Works with 0.6.0~~ (jl_init_with_image breaks with no error!)
* Works with 0.6.1

# Info
Builds an executable that doesn't require any julia source code.
The user needs to provide a julia script that contains a function main(),
taking no argument, which will be run when executing the
produced executable. An executable can be produced by using the `build_executable` function
```julia
using BuildExecutable
build_executable(exename, script, targetdir, "native")
```

## Note on packages:
Even if the script contains using statements, exported functions
will not be available in main(). Full qualification of names is
required. It's suggested to replace using statements with import
statements to produce a consistent result between running main() in
the REPL and running the executable. 

If packages with binary dependencies is used the produced executable will not function properly.

## Note on portability
The executable produced by `build_executable` is known to be portable across Windows computers, and OS X, but not on Linux. To increase the portablity use an older `cpu_target` target as `"core2"` instead of `"native"`. 
