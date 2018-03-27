# BuildExecutable
[![Build Status](https://travis-ci.org/Gilga/BuildExecutable.jl.svg?branch=master)](https://travis-ci.org/Gilga/BuildExecutable.jl)
[![Build status](https://ci.appveyor.com/api/projects/status/eoyxl4doixob24xc?svg=true)](https://ci.appveyor.com/project/Gilga/buildexecutable-jl)

Forked from [here](https://github.com/dhoegh/BuildExecutable.jl).

# Info
Builds an executable that doesn't require any julia source code.
The user needs to provide a julia script that contains a function main(),
taking no argument, which will be run when executing the
produced executable. An executable can be produced by using the `build_executable` function
```julia
using BuildExecutable
build_executable(exename, script, targetdir, "native")
```

# Status
* ~~Works with 0.5.1~~ (deprecated, not tested anymore!)
* ~~Works with 0.6.0~~ (jl_init_with_image breaks with no error!)
* Works with 0.6.1

# Requirements (Packages)
* WinRPM

# Tested on
## Windows
* Operating System: Windows 10 Home 64-bit (10.0, Build 16299) (16299.rs3_release.170928-1534)
* Processor: Intel(R) Core(TM) i7-4510U CPU @ 2.00GHz (4 CPUs), ~2.0GHz
* Memory: 8192MB RAM
* Graphics Card 1: Intel(R) HD Graphics Family
* Graphics Card 2: NVIDIA GeForce 840M

## Linux
* not tested
## Mac
* not tested


## Note on packages:
Even if the script contains using statements, exported functions
will not be available in main(). Full qualification of names is
required. It's suggested to replace using statements with import
statements to produce a consistent result between running main() in
the REPL and running the executable. 

If packages with binary dependencies is used the produced executable will not function properly.

## Note on portability
The executable produced by `build_executable` is known to be portable across Windows computers, and OS X, but not on Linux. To increase the portablity use an older `cpu_target` target as `"core2"` instead of `"native"`. 

# Compiling
using module namespace in non module context won't work so easily...

execution of main() will fail probably due to missing modules (even so i defined it). why? look:

**in non module context** ("using 'modulename'" has to be called in each function!)
```julia
function test()
  using Images
  Images.load(...)
end
```

**in module context**
```julia
module Test
  using Images
  
  function load()
    Images.load(...)
  end  
end
```

I guess the reason is that: app execution != compiler run. main() function will be called by a executable file (.exe) after code was compiled.

So question is if main() function can see all necessary modules i want to use.

I did an approach of defining an module 'App' around a start() function which is the programs run point (instead of using main).
All necessary files and modules are included there. The main function calls App.start(). This works!

Example:
```julia
module App
  include("myOtherModule")
  
  using Images
  using ImageMagick # add all dependencies here or run (of executable) will fail
  using myOtherModule
  ...
  
  function start() # app run point
    Images.load(...)
    myOtherModule.call()
  end
end

function main() # entry point
  App.start() # app run point
end
```