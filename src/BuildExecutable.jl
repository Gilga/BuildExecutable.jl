module BuildExecutable
export build_executable
using Compat
@static if is_windows() using WinRPM end
# Builds an executable that doesn't require any julia source code.
# The user needs to provide a julia script that contains a function main(),
# taking no argument, which will be run when executing the
# produced executable.

# Note on packages:
# Even if the script contains using statements, exported functions
# will not be available in main(). Full qualification of names is
# required. It's suggested to replace using statements with import
# statements to produce a consistent result between running main() in
# the REPL and running the executable.

type Executable
    name
    filename
		buildpath
    buildfile
    libjulia
		debug
		
		function Executable(exename, targetdir, debug=false)
				if debug
						exename = exename * "-debug"
				end
				filename = exename
				@static if is_windows()
						filename = filename * ".exe"
				end
				buildfile = abspath(joinpath(targetdir == nothing ? JULIA_HOME : targetdir, filename))
				libjulia = debug ? "-ljulia-debug" : "-ljulia"

				new(exename, filename, targetdir, buildfile, libjulia, debug)
		end
end

type SysFile
		buildpath
		buildfile
		inference
		
		function SysFile(exe_file)
				buildpath = abspath(dirname(Libdl.dlpath(exe_file.debug ? "libjulia-debug" : "libjulia")))
				buildfile = abspath(exe_file.buildpath, "lib"*exe_file.name) #joinpath(buildpath, "lib"*exe_file.name)
				inference = joinpath(buildpath, "inference")
				new(buildpath, buildfile, inference)
		end
end


function build_executable(exename, script_file, targetdir=nothing, cpu_target="native";
                          force=false, debug=false)
    julia = abspath(joinpath(JULIA_HOME, debug ? "julia-debug" : "julia"))
    if !isfile(julia * (is_windows() ? ".exe" : ""))
        println("ERROR: file '$(julia)' not found.")
        return 1
    end
    build_sysimg = abspath(dirname(@__FILE__), "build_sysimg.jl")
	if !isfile(build_sysimg)
		build_sysimg = abspath(JULIA_HOME, "..", "share", "julia", "contrib", "build_sysimg.jl") 
		if !isfile(build_sysimg)
			println("ERROR: build_sysimg.jl not found.")
			return 1
		end
	end

    if targetdir != nothing
        patchelf = find_patchelf()
        if patchelf == nothing && !(is_windows())
            println("ERROR: Using the 'targetdir' option requires the 'patchelf' utility. Please install it.")
            return 1
        end
    end

    if !isfile(script_file)
        println("ERROR: $(script_file) not found.")
        return 1
    end

    tmpdir = mktempdir()
    userimgjl = joinpath(tmpdir, "userimg.jl")
    script_file = abspath(script_file)

    if targetdir != nothing
        targetdir = abspath(targetdir)
        if !isdir(targetdir)
            println("ERROR: targetdir is not a directory.")
            return 1
        end
    end

    exe_file = Executable(exename, targetdir, debug)
    sys = SysFile(exe_file)
		
    if !force
        for f in [userimgjl, "$(sys.buildfile).$(Libdl.dlext)", "$(sys.buildfile).ji", exe_file.buildfile] #cfile, 
            if isfile(f)
                println("ERROR: File '$(f)' already exists. Delete it or use --force.")
                return 1
            end
        end

        if targetdir != nothing && !isempty(readdir(targetdir))
            println("ERROR: targetdir is not an empty diectory. Delete all contained files or use --force.")
            return 1
        end
    end

    gcc = find_system_gcc()
		rc = find_system_rc()
		
    win_arg = ``
    # This argument is needed for the gcc, see issue #9973
    @static if is_windows()
	    win_arg = Sys.WORD_SIZE==32 ? `-D_WIN32_WINNT=0x0502 -march=pentium4` : `-D_WIN32_WINNT=0x0502`
    end
    incs = get_includes()
    ENV2 = deepcopy(ENV)
    @static if is_windows()
        if contains(gcc, "WinRPM")
            # This should not bee necessary, it is done due to WinRPM's gcc's
            # include paths is not correct see WinRPM.jl issue #38
            ENV2["PATH"] *= ";" * dirname(gcc)
            push!(incs, "-I"*abspath(joinpath(dirname(gcc),"..","include")))
        end
    end
		
		# libs
		if !isfile(string(sys.buildfile, ".o"))
			println("[ Build Library ]")
			emit_userimgjl(userimgjl, script_file)
			empty_cmd_str = ``
			println("running: $(julia) $(build_sysimg) $(sys.buildfile) $(cpu_target) $(userimgjl) --force" * (debug ? " --debug" : ""))
			cmd = setenv(`$(julia) $(build_sysimg) $(sys.buildfile) $(cpu_target) $(userimgjl) --force $(debug ? "--debug" : empty_cmd_str)`, ENV2)
			run(cmd)
			println()
		end

		# build ressource file
		rcfile=string(joinpath(exe_file.buildpath, exe_file.name), ".rc")
		rcbuilfile=string(rcfile, ".o")
		
		if !isfile(rcbuilfile) || !isfile(rcfile)
			println("[ Build Ressource ]")
			if !isfile(rcfile)
				println("create $(rcfile)")
				emit_rc(rcfile, exe_file.filename, string(exe_file.name, ".ico"))
				println()
			end
			println("running: $rc  -i $(rcfile) -o $(rcbuilfile)")
			cmd = setenv(`$rc -i $(rcfile) -o $(rcbuilfile)`, ENV2)
			run(cmd)
			println()
		end
				
		# main
		cfile = joinpath(exe_file.buildpath, "main.c")
					
		if !isfile(cfile) || !isfile(exe_file.buildfile)
			println("[ Build Executable ]")
			if !isfile(cfile)
				println("create $(cfile)")
				emit_cmain(cfile, exename, targetdir != nothing)
				println()
			end
			println("running: $gcc -g $win_arg $(join(incs, " ")) $(cfile) -o $(exe_file.buildfile) $(rcbuilfile) -Wl,-rpath,$(exe_file.buildpath) -L$(exe_file.buildpath) $(exe_file.libjulia) -l$(exename)")
			cmd = setenv(`$gcc -g $win_arg $(incs) $(cfile) -o $(exe_file.buildfile) $(rcbuilfile) -Wl,-rpath,$(exe_file.buildpath) -Wl,-rpath,$(exe_file.buildpath*"/julia") -L$(exe_file.buildpath) $(exe_file.libjulia) -l$(exename)`, ENV2)
			run(cmd)
			println()
		end

		println("running: rm -rf $(tmpdir)") # $(sys.buildfile).o $(sys.inference).o $(sys.inference).ji")
		map(f-> rm(f, recursive=true), [tmpdir]) #, sys.buildfile*".o", sys.inference*".o", sys.inference*".ji"])
		println()
		
    if targetdir != nothing
				# deleted: not used anymore (build dir = target dir)
        # Move created files to target directory
        #for file in [exe_file.buildfile, sys.buildfile * ".$(Libdl.dlext)", sys.buildfile * ".o", sys.buildfile * ".ji"]
        #    mv(file, joinpath(targetdir, basename(file)), remove_destination=force)
        #end

        # Copy needed shared libraries to the target directory
        tmp = ".*\.$(Libdl.dlext).*"
        paths = [sys.buildpath]
        VERSION>v"0.5.0-dev+5537" && is_unix() && push!(paths, sys.buildpath*"/julia")
		
				once = true
				for path in paths
					shlibs = filter(Regex(tmp),readdir(path))
					for shlib in shlibs
						targetfile = joinpath(targetdir, shlib)
						if !isfile(targetfile)
							if once
								println("[ Copy Shared Libs ]")
								once=false
							end
							lib = joinpath(path, shlib)
							println("$(lib) -> $(targetfile)")
							cp(lib, targetfile, remove_destination=force)
						end
					end
				end
				if !once
					println()
				end

        @static if is_unix()
            # Fix rpath in executable and shared libraries
            # old implementation for fixing rpath in shared libraries
            #=
            shlibs = filter(Regex(tmp),readdir(targetdir))
            push!(shlibs, exe_file.filename)
            for shlib in shlibs
                rpath = readall(`$(patchelf) --print-rpath $(joinpath(targetdir, shlib))`)[1:end-1]
                # For debug purpose
                #println("shlib=$shlib\nrpath=$rpath")
                if Base.samefile(rpath, sys.buildpath)
                    run(`$(patchelf) --set-rpath $(targetdir) $(joinpath(targetdir, shlib))`)
                end
            end
            =#
            # New implementation
            shlib = exe_file.filename
            @static if is_linux()
                run(`$(patchelf) --set-rpath \$ORIGIN/ $(joinpath(targetdir, shlib))`)
            end
            @static if is_apple()
                # For debug purpose
                #println(readall(`otool -L $(joinpath(targetdir, shlib))`)[1:end-1])
                #println("sys.buildfile=",sys.buildfile)
                run(`$(patchelf) -rpath $(sys.buildpath) @executable_path/ $(joinpath(targetdir, shlib))`)
                run(`$(patchelf) -change $(sys.buildfile).$(Libdl.dlext) @executable_path/$(basename(sys.buildfile)).$(Libdl.dlext) $(joinpath(targetdir, shlib))`)
                #println(readall(`otool -L $(joinpath(targetdir, shlib))`)[1:end-1])
            end
        end
    end

    println("Build Sucessful.")
    return 0
end

function find_patchelf()
    installed_version = joinpath(dirname(dirname(@__FILE__)), "deps", "usr", "local", "bin", "patchelf")
    @static if is_linux()
        for patchelf in [joinpath(JULIA_HOME, "patchelf"), "patchelf", installed_version]
            try
                if success(`$(patchelf) --version`)
                    return patchelf
                end
            end
        end
    end
    @static if is_apple() "install_name_tool" end
end

function get_includes()
    ret = []

    # binary install
    incpath = abspath(joinpath(JULIA_HOME, "..", "include", "julia"))
    push!(ret, "-I$(incpath)")

    # Git checkout
    julia_root = abspath(joinpath(JULIA_HOME, "..", ".."))
    push!(ret, "-I$(julia_root)src")
    push!(ret, "-I$(julia_root)src/support")
    push!(ret, "-I$(julia_root)usr/include")

    ret
end

function emit_rc(file, exename, iconname, productversion="1.0.0.0", fileversion="1.0.0.0")
    code = """
		1 VERSIONINFO
		FILEVERSION     $(replace(fileversion, ".", ","))
		PRODUCTVERSION  $(replace(productversion, ".", ","))
		FILEFLAGSMASK  	0x3fL
		#ifdef _DEBUG
		FILEFLAGS		0x9L
		#else
		FILEFLAGS		0x8L
		#endif
		FILEOS			0x40004L
		FILETYPE		0x2L
		FILESUBTYPE	0x0L
		BEGIN
			BLOCK "StringFileInfo"
			BEGIN
				BLOCK "040904E4"
				BEGIN
					VALUE "Comments", "\\0"
					VALUE "CompanyName", "\\0"
					VALUE "FileDescription", "\\0"
					VALUE "FileVersion", "$(productversion)\\0"
					VALUE "InternalName", "\\0"
					VALUE "LegalCopyright", "\\0"
					VALUE "LegalTrademarks", "\\0"
					VALUE "OriginalFilename", "$(exename)\\0"
					VALUE "PrivateBuild", "\\0"
					VALUE "ProductName", "\\0"
					VALUE "ProductVersion", "$(fileversion)\\0"
					VALUE "SpecialBuild", "\\0"
				END
			END
			BLOCK "VarFileInfo"
			BEGIN
				// US English, Unicode
				VALUE "Translation", 0x409, 1200
			END
		END
		2 ICON "$(iconname)"
		//1 RT_MANIFEST "app-manifest.xml"
		"""
		f = open(file, "w")
    write(f, code)
    close(f)
end

function emit_cmain(cfile, exename, relocation)
    if relocation
        sysji = joinpath("lib"*exename)
    else
        sysji = joinpath(dirname(Libdl.dlpath("libjulia")), "lib"*exename)
    end
    sysji = escape_string(sysji)
    if VERSION > v"0.5.0-dev+4397"
        arr = "jl_alloc_vec_any"
        str = "jl_string_type"
    else
        arr = "jl_alloc_cell_1d"
        str = "jl_utf8_string_type"
    end
    ext = (VERSION < v"0.5" &&  is_windows()) ? "ji" : Libdl.dlext

		# works in 0.5.1
    exampleCode = """
		#include <julia.h>
		#include <stdio.h>

		JULIA_DEFINE_FAST_TLS(); // only define this once, in an executable
		
		void failed_warning(void) {
				if (jl_base_module == NULL) { // image not loaded!
						char *julia_home = getenv("JULIA_HOME");
						if (julia_home) {
								fprintf(stderr,
												"\\nJulia init failed, "
												"a possible reason is you set an envrionment variable named 'JULIA_HOME', "
												"please unset it and retry.\\n");
						}
				}
		}

		int main()
		{
			char sysji[] = "$(sysji).$ext";
		  char *sysji_env = getenv("JULIA_SYSIMAGE");
			
			printf("My Example\\n");
			
      assert(atexit(&failed_warning) == 0);
				
      jl_init_with_image(NULL, sysji_env == NULL ? sysji : sysji_env);
						
			jl_eval_string("println(24)");
			int ret = 0;
			jl_atexit_hook(ret);
			return ret;
		}
	  """
		
    mainCode = """
		#include <julia.h>
		#include <stdlib.h>
		#include <stdio.h>
		#include <assert.h>
		#include <string.h>
		#if defined(_WIN32) || defined(_WIN64)
		#include <malloc.h>
		#endif
		
		JULIA_DEFINE_FAST_TLS(); // only define this once, in an executable

		void failed_warning(void) {
				if (jl_base_module == NULL) { // image not loaded!
						char *julia_home = getenv("JULIA_HOME");
						if (julia_home) {
								fprintf(stderr,
												"\\nJulia init failed, "
												"a possible reason is you set an envrionment variable named 'JULIA_HOME', "
												"please unset it and retry.\\n");
						}
				}
		}

		int main(int argc, char *argv[])
		{
				char * arg;
				char *token;
				char *split=":";
				
				for (int i = 1; i < argc; i++) {
						arg = argv[i];
						token = strtok(arg, split);
						if(strcmp ("env",token) == 0){
								token = strtok(NULL, split);
								if(token!=0) { putenv (token); }
						}
				}
				
				char sysji[] = "$(sysji).$ext";
				char *sysji_env = getenv("JULIA_SYSIMAGE");
				char mainfunc[] = "main()";

				assert(atexit(&failed_warning) == 0);
		
				jl_init_with_image(NULL, sysji_env == NULL ? sysji : sysji_env);

				// set Base.ARGS, not Core.ARGS
				if (jl_base_module != NULL) {
						jl_array_t *args = (jl_array_t*)jl_get_global(jl_base_module, jl_symbol("ARGS"));
						if (args == NULL) {
								args = $arr(0);
								jl_set_const(jl_base_module, jl_symbol("ARGS"), (jl_value_t*)args);
						}
						assert(jl_array_len(args) == 0);
						jl_array_grow_end(args, argc - 1);
						int i;
						for (i=1; i < argc; i++) {
								jl_value_t *s = (jl_value_t*)jl_cstr_to_string(argv[i]);
								jl_set_typeof(s,$str);
								jl_arrayset(args, s, i - 1);
						}
				}
				
				// call main
				jl_eval_string(mainfunc);

				int ret = 0;
				if (jl_exception_occurred())
				{
						//jl_show(jl_stderr_obj(), jl_exception_occurred());
						jl_call2(jl_get_function(jl_base_module, "show"), jl_stderr_obj(), jl_exception_occurred());
						jl_printf(jl_stderr_stream(), "\\n");
						ret = 1;
				}

				jl_atexit_hook(ret);
				return ret;
		}
		"""
				
		f = open(cfile, "w")
    write( f, mainCode)
    close(f)
end

function emit_userimgjl(userimgjl, script_file)
    open(userimgjl, "w") do f
        write( f, "include(\"$(escape_string(script_file))\")")
    end
end

function find_system_rc()
    # On Windows, check to see if WinRPM is installed, and if so, see if windres is installed
    @static if is_windows()
        try
            winrpmrc = joinpath(WinRPM.installdir,"usr","$(Sys.ARCH)-w64-mingw32", "sys-root","mingw","bin","windres.exe")
            if success(`$winrpmrc --version`)
                return winrpmrc
            end
        end
    end

    # See if `gcc` exists
    @static if is_unix()
        try
            if success(`rc -v`)
                return "rc"
            end
        end
    end

    error( "RC not found on system: " * (is_windows() ? "windres can be installed via `Pkg.add(\"WinRPM\"); WinRPM.install(\"gcc\")`" : "" ))
end

function find_system_gcc()
    # On Windows, check to see if WinRPM is installed, and if so, see if gcc is installed
    @static if is_windows()
        try
            winrpmgcc = joinpath(WinRPM.installdir,"usr","$(Sys.ARCH)-w64-mingw32", "sys-root","mingw","bin","gcc.exe")
            if success(`$winrpmgcc --version`)
                return winrpmgcc
            end
        end
    end

    # See if `gcc` exists
    @static if is_unix()
        try
            if success(`gcc -v`)
                return "gcc"
            end
        end
    end

    error( "GCC not found on system: " * (is_windows() ? "GCC can be installed via `Pkg.add(\"WinRPM\"); WinRPM.install(\"gcc\")`" : "" ))
end

end # module
