using Pkg

# Collection of sources required to build Arpack
function arpack_sources(version::VersionNumber; kwargs...)
    arpack_version_sources = Dict(
        v"3.9.1" => [
	    GitSource("https://github.com/opencollab/arpack-ng.git",
		      "40329031ae8deb7c1e26baf8353fa384fc37c251"),
        ]
    )
    return Any[
        arpack_version_sources[version]...,
    ]

end

# Bash recipe for building across all platforms
function build_script(;build_32bit::Bool=false)

script = """
ARPACK32=$(build_32bit)
"""

script *= raw"""
cd ${WORKSPACE}/srcdir/arpack-ng*

SYMBOL_DEFS=()
if [[ ${ARPACK32} == true ]]; then
   # Symbols that have float32, float64, complexf32, and complexf64 support
   SDCZ_SYMBOLS=(
        axpy copy gemv geqr2 lacpy lahqr lanhs larnv lartg
        lascl laset scal trevc trmm trsen gbmv gbtrf gbtrs
        gttrf gttrs pttrf pttrs
   )

   # All symbols that have float32/float64 support (including the SDCZ_SYMBOLS above)
   SD_SYMBOLS=(
         ${SDCZ_SYMBOLS[@]}
         dot ger labad laev2 lamch lanst lanv2
         lapy2 larf larfg lasr nrm2 orm2r rot steqr swap
   )

   # All symbols that have complexf32/complexf64 support (including the SDCZ_SYMBOLS above)
   CZ_SYMBOLS=(${SDCZ_SYMBOLS[@]} dotc geru unm2r)

   # Add in (s|d)*_64 symbol remappings:
   for sym in ${SD_SYMBOLS[@]}; do
      SYMBOL_DEFS+=("-Ds${sym}=s${sym}_64" "-Dd${sym}=d${sym}_64")
   done

   # Add in (c|z)*_64 symbol remappings:
   for sym in ${CZ_SYMBOLS[@]}; do
      SYMBOL_DEFS+=("-Dc${sym}=c${sym}_64" "-Dz${sym}=z${sym}_64")
   done

   # Add one-off symbol mappings; things that don't fit into any other bucket:
   for sym in scnrm2 dznrm2 csscal zdscal dgetrf dgetrs; do
       SYMBOL_DEFS+=("-D${sym}=${sym}_64")
   done
fi

# Set up not only lowercase symbol remappings, but uppercase as well:
SYMBOL_DEFS+=(${SYMBOL_DEFS[@]^^})

FFLAGS="${FFLAGS} -O3 -fPIE -ffixed-line-length-none -fno-optimize-sibling-calls -cpp"

if [[ "${target}" == *-mingw* ]]; then
    LBT=blastrampoline-5
else
    LBT=blastrampoline
fi

if [[ ${ARPACK32} == false ]] && [[ ${nbits} == 64 ]]; then
    FFLAGS="${FFLAGS} -fdefault-integer-8 ${SYMBOL_DEFS[@]}"
fi

mkdir build
cd build
export LDFLAGS="-L${libdir} -lpthread"
cmake .. -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DCMAKE_TOOLCHAIN_FILE="${CMAKE_TARGET_TOOLCHAIN}" -DCMAKE_BUILD_TYPE=Release \
    -DEXAMPLES=OFF \
    -DBUILD_SHARED_LIBS=ON \
    -DBLAS_LIBRARIES="-l${LBT}" \
    -DLAPACK_LIBRARIES="-l${LBT}" \
    -DCMAKE_Fortran_FLAGS="${FFLAGS}"

make -j${nproc} VERBOSE=1
make install VERBOSE=1

# For now, we'll have to adjust the name of the Lbt library on macOS and FreeBSD.
# Eventually, this should be fixed upstream
if [[ ${target} == *-apple-* ]] || [[ ${target} == *freebsd* ]]; then
    echo "-- Modifying library name for Lbt"

    for nm in libarpack; do
        # Figure out what version it probably latched on to:
        if [[ ${target} == *-apple-* ]]; then
            LBT_LINK=$(otool -L ${libdir}/${nm}.dylib | grep lib${LBT} | awk '{ print $1 }')
            install_name_tool -change ${LBT_LINK} @rpath/lib${LBT}.dylib ${libdir}/${nm}.dylib
        elif [[ ${target} == *freebsd* ]]; then
            LBT_LINK=$(readelf -d ${libdir}/${nm}.so | grep lib${LBT} | sed -e 's/.*\[\(.*\)\].*/\1/')
            patchelf --replace-needed ${LBT_LINK} lib${LBT}.so ${libdir}/${nm}.so
        elif [[ ${target} == *linux* ]]; then
            LBT_LINK=$(readelf -d ${libdir}/${nm}.so | grep lib${LBT} | sed -e 's/.*\[\(.*\)\].*/\1/')
            patchelf --replace-needed ${LBT_LINK} lib${LBT}.so ${libdir}/${nm}.so
        fi
    done
fi

# Delete the extra soversion libraries built. https://github.com/JuliaPackaging/Yggdrasil/issues/7
if [[ "${target}" == *-mingw* ]]; then
    rm -f ${libdir}/lib*.*.${dlext}
    rm -f ${libdir}/lib*.*.*.${dlext}
fi
"""
end # function build_script(...)

# These are the platforms we will build for by default, unless further
# platforms are passed in on the command line.  We enable the full
# combinatorial explosion of GCC versions because this package most
# definitely links against libgfortran.
platforms = expand_gfortran_versions(supported_platforms())

# Dependencies that must be installed before this package can be built
dependencies = [
    Dependency("CompilerSupportLibraries_jll"),
    Dependency(PackageSpec(name="libblastrampoline_jll", uuid="8e850b90-86db-534c-a0d3-1478176c7d93"), compat="5.4.0"),
]
