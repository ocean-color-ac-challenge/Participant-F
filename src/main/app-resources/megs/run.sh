#!/bin/bash

# This document is the property of Terradue and contains information directly
# resulting from knowledge and experience of Terradue.
# Any changes to this code is forbidden without written consent from Terradue Srl
#
# Contact: info@terradue.com

# source the ciop functions (e.g. ciop-log)
source ${ciop_job_include}
export LC_ALL="en_US.UTF-8"

# define the exit codes
SUCCESS=0
ERR_NOINPUT=3
ERR_NOADF=4
ERR_MEGS=5
ERR_PCONVERT=8
ERR_TAR=10
ERR_JAVAVERSION=15

# add a trap to exit gracefully
function cleanExit ()
{
  local retval=$?
  local msg=""
  case ${retval} in
    ${SUCCESS})   msg="Processing successfully concluded";;
    ${ERR_NOINPUT})  msg="Input not retrieved to local node";;
    ${ERR_MEGS})  msg="megs returned an error";;
    ${ERR_NOADF})  msg="Could not retrieve custom ADF";;
    ${ERR_PCONVERT})  msg="Conversion to BEAM-DIMAP failed";;
    ${ERR_TAR})  msg="Compression of BEAM-DIMAP failed";;
    ${ERR_JAVAVERSION}) msg="The version of the JVM must be at least 1.7";;
    *)    msg="Unknown error";;
  esac

  [ ${retval} -ne "0" ] && ciop-log "ERROR" "Error ${retval} - ${msg}, processing aborted" || ciop-log "INFO" "${msg}"

  exit ${retval}
}

trap cleanExit EXIT

ciop-log "INFO" "Checking Java version"
${_CIOP_APPLICATION_PATH}/shared/bin/detect_java.sh
[ "$?" == "0" ] || exit ${ERR_JAVAVERSION}

megsDir=${TMPDIR}/megs/processors/MEGS_8.1/
inputDir=${megsDir}/input
outputDir=${megsDir}/output

prdurl="$( ciop-getparam prdurl )"
if [ "${prdurl}" == "default" ]; then
  prdurl=""
else
  ciop-log "INFO" "Getting custom ADFs from ${prdurl}"
  localprd="$( echo ${prdurl} | ciop-copy -U -o ${TMPDIR} - )"
  [ $? -ne 0 ] && exit ${ERR_NOADF}
  ciop-log "INFO" "Using custom ADFs with archive signature $( md5sum ${localprd} )"
  prdurl="file://${localprd}"
fi

mkdir -p ${megsDir}

while read input
do
  #environment setup
  mkdir -p ${inputDir}
  mkdir -p ${outputDir}

  cd ${inputDir}
  
  ciop-log "INFO" "Working with file ${input}"
  file=$( echo ${input} | ciop-copy -o . - )
  [ $? -ne 0 ] && exit ${ERR_NOINPUT}
  
  # checks if it's a RR, FR or FRS
  filetype=$( basename ${file} | cut -c 1-10 )

  #prepares the environment
  ciop-log "INFO" "Preparing MEGS environment"
  mkdir -p ${megsDir}/configurations/Reference_Configuration
  cd ${megsDir}/configurations/Reference_Configuration
  cp -R /usr/local/MEGS_8.1/configurations/Reference_Configuration/resources .
  cp -R /usr/local/MEGS_8.1/configurations/Reference_Configuration/configuration.conf .
  mkdir -p job_groups/myjob
  cd job_groups/myjob
  cp -R /usr/local/MEGS_8.1/templates/* .
    
  #sets the correct modifiers.db and value.txt
  cp run/value.${filetype}.txt run/value.txt
  cp run/modifiers.${filetype}.db run/modifiers.db
  
  # instantiates the templates
  sed -i "s#inputfile: #inputfile: ${file}#g" ${megsDir}/configurations/Reference_Configuration/job_groups/myjob/job.conf
  sed -i "s#export DATABASE_DIR=.*#export DATABASE_DIR=${megsDir}/configurations/Reference_Configuration/job_groups/myjob/run/database#g" ${megsDir}/configurations/Reference_Configuration/job_groups/myjob/run/run_megs.sh

  cd ${megsDir}/configurations/Reference_Configuration/job_groups/myjob/run
  ln -s ${outputDir} output

  ciop-log "INFO" "Starting megs processor"
  sh run_megs.sh "${file}" ${prdurl} 

  [ $? -ne 0 ] && exit ${ERR_MEGS}
  
  ciop-log "INFO" "Conversion to BEAM-DIMAP format"
  l2="$( find ${outputDir} -type f -name "MER*.N1" )"
  ciop-log "DEBUG" "found: ${l2}"
  /application/shared/bin/pconvert.sh --outdir ${outputDir} ${l2}  
  [ $? -ne 0 ] && exit ${ERR_PCONVERT}

  # create RGB quicklook
  outputname=$( basename ${l2} | sed 's#\.N1##g' )
  ${_CIOP_APPLICATION_PATH}/shared/bin/pconvert.sh \
    -f png \
    -p ${_CIOP_APPLICATION_PATH}/megs/etc/profile.rgb \
    -o ${myOutput} \
    ${myOutput}/${outputname}.dim

  ciop-log "INFO" "Publishing png"
  ciop-publish -m ${myOutput}/${outputname}.png

  [ "${pixex}" == "true" ] && {
    # get the POIs
    echo -e "Name\tLatitude\tLongitude" > ${TMPDIR}/poi.csv
    echo "$( ciop-getparam poi | tr ',' '\t' | tr '|' '\n' )" >> ${TMPDIR}/poi.csv

    # get the window size
    window="$( ciop-getparam window )"
    aggregation="$( ciop-getparam aggregation )"

    # invoke pixex
    l2b="$( basename ${l2output} | sed 's#\.L2$#.dim#g')"
    prddate="${l2b:20:2}/${l2b:18:2}/${l2b:14:4}"
    ciop-log "INFO" "Apply BEAM PixEx Operator to ${l2b}"
    prd_orbit=$( echo ${l2b:49:5} | sed 's/^0*//' )
    run=${CIOP_WF_RUN_ID}

    # apply PixEx BEAM operator
    ${_CIOP_APPLICATION_PATH}/shared/bin/gpt.sh \
      -Pvariable=${l2b} \
      -Pvariable_path=${myOutput} \
      -Poutput_path=${myOutput} \
      -Pprefix=${run} \
      -Pcoordinates=${TMPDIR}/poi.csv \
      -PwindowSize=${window} \
      -PaggregatorStrategyType="${aggregation}" \
      ${_CIOP_APPLICATION_PATH}/pixex/libexec/PixEx.xml 1>&2

    res=$?
    [ ${res} -ne 0 ] && exit ${ERR_BEAM_PIXEX}

    result="$( find ${myOutput} -name "${run}*measurements.txt" )"

    [ -n "${result}" ] && {
      skip_lines=$( cat "${result}" | grep -n "ProdID" | cut -d ":" -f 1 )

      cat "${result}" |  tail -n +${skip_lines} | tr "\t" "," | awk -f ${_CIOP_APPLICATION_PATH}/pixex/libexec/tidy.awk -v run=${run} -v date=${prddate} -v orbit=${prd_orbit} - > "${myOutput}/${l2b}.txt"

      ciop-log "INFO" "Publishing extracted pixel values"
      ciop-publish -m "${myOutput}/${l2b}.txt"
      rm -f "${myOutput}/${l2b}.txt"
    }
  }

  ciop-log "INFO" "Compressing results"
  tar -C ${outputDir} -cvzf ${l2}.tgz $( basename ${l2} | sed 's#\.N1$#.dim#g' ) $( basename ${l2} | sed 's#\.N1$#.data#g' )
  [ $? -ne 0 ] && exit ${ERR_TAR}

  #publishing the output
  ciop-log "INFO" "Publishing $( basename ${l2} ).tgz"
  ciop-publish -m ${l2}.tgz 

  #clears the directory for the next file
  rm -rf ${megsDir}/*
done
