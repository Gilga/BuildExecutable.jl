#!/usr/bin/env julia
# This file is a part of Julia. License is MIT: https://julialang.org/license

# Build a system image binary at build_path.dlext. Allow insertion of a userimg via
# userimg_path.  If build_path.dlext is currently loaded into memory, don't continue
# unless force is set to true.  Allow targeting of a CPU architecture via cpu_target.
function default_sysimg_path(debug=false)
    if is_unix()
        splitext(Libdl.dlpath(debug ? "sys-debug" : "sys"))[1]
    else
        joinpath(dirname(JULIA_HOME), "lib", "julia", debug ? "sys-debug" : "sys")
    end
end

"""
    build_sysimg(build_path=default_sysimg_path, cpu_target="native", userimg_path=nothing; force=false)

Rebuild the system image. Store it in `build_path`, which defaults to a file named `sys.ji`
that sits in the same folder as `libjulia.{so,dylib}`, except on Windows where it defaults
to `JULIA_HOME/../lib/julia/sys.ji`.  Use the cpu instruction set given by `cpu_target`.
Valid CPU targets are the same as for the `-C` option to `julia`, or the `-march` option to
`gcc`.  Defaults to `native`, which means to use all CPU instructions available on the
current processor. Include the user image file given by `userimg_path`, which should contain
directives such as `using MyPackage` to include that package in the new system image. New
system image will not replace an older image unless `force` is set to true.
"""
function build_sysimg(buildfile=nothing, cpu_target="native", userimg_path=nothing; force=false, debug=false)
    #buildfile = buildfile
    build_path = dirname(buildfile)
    
    if build_path === nothing
        build_path = default_sysimg_path(debug)
    end

    # Quit out if a sysimg is already loaded and is in the same spot as build_path, unless forcing
    lib = Libdl.dlopen_e("sys")
    if lib != C_NULL
        if !force && Base.samefile(Libdl.dlpath(lib), "$buildfile.$(Libdl.dlext)")
            info("System image already loaded at $(Libdl.dlpath(lib)), set force=true to override.")
            return nothing
        end
    end

    # Canonicalize userimg_path before we enter the base_dir
    if userimg_path !== nothing userimg_path = abspath(userimg_path) end

		file_coreimg = "coreimg.jl"
		file_sysimg = "sysimg.jl"
		file_userimg = "userimg_tmp.jl"
#tempname()
    # Enter base and setup some useful paths
    r=Base.find_source_file("$file_sysimg")
    if r == nothing error("Could not find $file_sysimg") end
    
    cd(dirname(Base.find_source_file("sysimg.jl"))) do
        julia = joinpath(JULIA_HOME, debug ? "julia-debug" : "julia")
        cc = find_system_compiler()
        env=compiler_setPaths(cc,build_path)
        
        # Ensure we have write-permissions to wherever we're trying to write to
        try
            touch("$buildfile.ji")
        catch
            err_msg =  "Unable to modify $buildfile.ji, ensure parent directory exists "
            err_msg *= "and is writable; absolute paths work best.)"
            error(err_msg)
        end
				
        # Copy in userimg.jl if it exists
        if userimg_path !== nothing
            if !isfile(userimg_path)
                error("$userimg_path is not found, ensure it is an absolute path.")
            end
            #if isfile(file_userimg)
	                #error("$file_userimg already exists, delete manually to continue.")
            #end
            #cp(userimg_path, file_userimg, remove_destination=true)
        end
				
        try
            # paths for standard images
            recompile = false
            
            files = [file_coreimg,file_sysimg,"$buildfile.jl"]
            last = length(files)
            prepath = nothing
            i = 0
            
            for file in files
              i += 1
              name=splitext(file)[1]
              path=joinpath(build_path, name)
              
              if !isfile("$path.ji") || !isfile("$path.o")
                info("Building $name.o")
                #cmd has issues with space insertions!!!
                # cmd1=`"a" `; cmd2=`"b"`; cmd=`$cmd1$cmd2` -> `"a" "b"` won't work!
                link =prepath != nothing ? `-J "$prepath.ji" --startup-file=no "$file"` : `"$file"`
                cmd=`$julia -C $cpu_target --output-ji "$path.ji" --output-o "$path.o" $link`
                #startup = i >= last ? " --startup-file=no " :""
                info(cmd)
                run(cmd) #setenv(,env)
                recompile = true
              end
              prepath = path
            end
            
            if cc !== nothing
                link_sysimg(buildfile, cc, debug)
            else
                info("System image successfully built at $buildfile.ji.")
            end

            if !Base.samefile("$(default_sysimg_path(debug)).ji", "$buildfile.ji")
                if Base.isfile("$buildfile.$(Libdl.dlext)")
                    info("To run Julia with this image loaded, run: `julia -J $buildfile.$(Libdl.dlext)`.")
                else
                    info("To run Julia with this image loaded, run: `julia -J $buildfile.ji`.")
                end
            else
                info("Julia will automatically load this system image at next startup.")
            end
        catch(ex)
            println(STDERR,ex)
        finally
            # Cleanup userimg.jl
            #if userimg_path !== nothing && isfile(file_userimg) rm(file_userimg) end
        end
    end
end

# Search for a compiler to link sys.o into sys.dl_ext.  Honor LD environment variable.
function find_system_compiler()
    if haskey(ENV, "CC")
        if !success(`$(ENV["CC"]) -v`)
            warn("Using compiler override $(ENV["CC"]), but unable to run `$(ENV["CC"]) -v`.")
        end
        return ENV["CC"]
    end

    # On Windows, check to see if WinRPM is installed, and if so, see if gcc is installed
    if is_windows()
        try
            eval(Main, :(using WinRPM))
            winrpmgcc = joinpath(WinRPM.installdir, "usr", "$(Sys.ARCH)-w64-mingw32",
                "sys-root", "mingw", "bin", "gcc.exe")
            if success(`$winrpmgcc --version`)
                return winrpmgcc
            else
                throw()
            end
        catch
            warn("Install GCC via `Pkg.add(\"WinRPM\"); WinRPM.install(\"gcc\")` to generate sys.dll for faster startup times.")
        end
    end


    # See if `cc` exists
    try
        if success(`cc -v`)
            return "cc"
        end
    end

    warn("No supported compiler found; startup times will be longer.")
end

# Link sys.o into sys.$(dlext)
function link_sysimg(buildfile, cc=find_system_compiler(), debug=false)
    julia_libdir = dirname(Libdl.dlpath(debug ? "libjulia-debug" : "libjulia"))

    FLAGS = ["-L$julia_libdir"]

    push!(FLAGS, "-shared")
    push!(FLAGS, debug ? "-ljulia-debug" : "-ljulia")
    if is_windows()
        push!(FLAGS, "-lssp")
    end

    info("Linking $buildfile.$(Libdl.dlext)")
    info("$cc $(join(FLAGS, ' ')) -o $buildfile.$(Libdl.dlext) $buildfile.o")
    # Windows has difficulties overwriting a file in use so we first link to a temp file
    if is_windows() && isfile("$buildfile.$(Libdl.dlext)")
        if success(pipeline(`$cc $FLAGS -o $buildfile.tmp $buildfile.o`; stdout=STDOUT, stderr=STDERR))
            mv("$buildfile.$(Libdl.dlext)", "$buildfile.$(Libdl.dlext).old"; remove_destination=true)
            mv("$buildfile.tmp", "$buildfile.$(Libdl.dlext)"; remove_destination=true)
        end
    else
        run(`$cc $FLAGS -o "$buildfile.$(Libdl.dlext)" "$buildfile.o"`)
    end
    info("System image successfully built at $buildfile.$(Libdl.dlext)")
end

function compiler_setPaths(gcc,env_path)
  # set paths
  binary_path = dirname(gcc)
  inlcude_path = joinpath(abspath(binary_path,"../"),"include")
  lib_path = joinpath(abspath(binary_path,"../"),"lib")

  ENV2 = deepcopy(ENV)
  ENV2["CPATH"] = ""
  ENV2["LIBRARY_PATH"] = ""

  ENV2["PATH"] *= ";" * env_path
  ENV2["PATH"] *= ";" * binary_path

  ENV2["CPATH"] *= ";" * inlcude_path

  ENV2["LIBRARY_PATH"] *= ";" * env_path
  ENV2["LIBRARY_PATH"] *= ";" * binary_path
  ENV2["LIBRARY_PATH"] *= ";" * lib_path
  
  ENV2
end

# When running this file as a script, try to do so with default values.  If arguments are passed
# in, use them as the arguments to build_sysimg above.
#
# Also check whether we are running `genstdlib.jl`, in which case we don't want to build a
# system image and instead only need `build_sysimg`'s docstring to be available.
if !isdefined(Main, :GenStdLib) && !isinteractive()
    if length(ARGS) > 5 || ("--help" in ARGS || "-h" in ARGS)
        println("Usage: build_sysimg.jl <build_path> <cpu_target> <usrimg_path.jl> [--force] [--debug] [--help]")
        println("   <build_path>    is an absolute, extensionless path to store the system image at")
        println("   <cpu_target>     is an LLVM cpu target to build the system image against")
        println("   <usrimg_path.jl> is the path to a user image to be baked into the system image")
        println("   --debug          Using julia-debug instead of julia to build the system image")
        println("   --force          Set if you wish to overwrite the default system image")
        println("   --help           Print out this help text and exit")
        println()
        println(" Example:")
        println("   build_sysimg.jl /usr/local/lib/julia/sys core2 ~/my_usrimg.jl --force")
        println()
        println(" Running this script with no arguments is equivalent to:")
        println("   build_sysimg.jl $(default_sysimg_path()) native")
        return 0
    end

    debug_flag = "--debug" in ARGS
    filter!(x -> x != "--debug", ARGS)
    force_flag = "--force" in ARGS
    filter!(x -> x != "--force", ARGS)
    build_sysimg(ARGS...; force=force_flag, debug=debug_flag)
end
