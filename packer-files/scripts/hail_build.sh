#!/bin/bash
set -x -e
export PATH=$PATH:/usr/local/bin

HAIL_ARTIFACT_DIR="/opt/hail"
HAIL_PROFILE="/etc/profile.d/hail.sh"
JAR_HAIL="hail-all-spark.jar"
ZIP_HAIL="hail-python.zip"
REPOSITORY_URL="https://github.com/hail-is/hail.git"

function install_prereqs {
  mkdir -p "$HAIL_ARTIFACT_DIR"

  yum -y remove java-1.7.0-openjdk*

  yum install -y gcc-c++

  yum -y update

  amazon-linux-extras install python3.8
  update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.8 1
  update-alternatives --install /usr/bin/python python /usr/bin/python3.8 1
  yum -y install python38-devel
  rm /usr/bin/python3
  ln -s /usr/bin/python3.8 /usr/bin/python3

  yum -y install \
  cmake \
  gcc72-c++ \
  git \
  java-1.8.0-openjdk \
  java-1.8.0-openjdk-devel \
  lz4 \
  lz4-devel \
  blas

  WHEELS="argparse
  bokeh
  cycler
  decorator
  joblib
  jupyter
  kiwisolver
  llvmlite
  matplotlib
  numba
  numpy
  oauth
  pandas
  parsimonious
  pyserial
  requests
  scikit-learn
  scipy
  seaborn
  statsmodels
  umap-learn
  utils
  wheel
  phantomjs
  selenium
  boto3
  awscli
  ipykernel
  pyspark
  ipython"

  for WHEEL_NAME in $WHEELS
  do
    python3.8 -m pip install "$WHEEL_NAME"
  done
}

function compare_versions
{
  # Trivial v1 == v2 test based on string comparison
  [[ "$1" == "$2" ]] && echo "0" && return

  # Local variables
  local regex="^(.*)-r([0-9]*)$" va1=() vr1=0 va2=() vr2=0 len i IFS="."

  # Split version strings into arrays, extract trailing revisions
  if [[ "$1" =~ ${regex} ]]; then
      va1=(${BASH_REMATCH[1]})
      [[ -n "${BASH_REMATCH[2]}" ]] && vr1=${BASH_REMATCH[2]}
  else
      va1=($1)
  fi
  if [[ "$2" =~ ${regex} ]]; then
      va2=(${BASH_REMATCH[1]})
      [[ -n "${BASH_REMATCH[2]}" ]] && vr2=${BASH_REMATCH[2]}
  else
      va2=($2)
  fi

  # Bring va1 and va2 to same length by filling empty fields with zeros
  (( ${#va1[@]} > ${#va2[@]} )) && len=${#va1[@]} || len=${#va2[@]}
  for ((i=0; i < len; ++i)); do
      [[ -z "${va1[i]}" ]] && va1[i]="0"
      [[ -z "${va2[i]}" ]] && va2[i]="0"
  done

  # Append revisions, increment length
  va1+=($vr1)
  va2+=($vr2)
  len=$((len+1))

  # *** DEBUG ***
  #echo "TEST: '${va1[@]} (?) ${va2[@]}'"

  # Compare version elements, check if v1 > v2 or v1 < v2
  for ((i=0; i < len; ++i)); do
      if (( 10#${va1[i]} > 10#${va2[i]} )); then
          echo "1"
          return
      elif (( 10#${va1[i]} < 10#${va2[i]} )); then
          echo "2"
          return
      fi
  done

  # All elements are equal, thus v1 == v2
  echo "0"
}

function hail_build
{
  echo "Building Hail v.$HAIL_VERSION from source with Spark v.$SPARK_VERSION"

  git clone "$REPOSITORY_URL"
  cd hail/hail/
  git checkout "$HAIL_VERSION"

  JAVA_PATH=$(dirname "/usr/lib/jvm/java-1.8.0/include/.")
  echo $JAVA_PATH
  if [ -z "$JAVA_PATH" ]; then
    echo "Java 8 was not found"
    exit 1
  else
    ln -s "$JAVA_PATH" /etc/alternatives/jre/include
  fi

  TEST1=$(compare_versions "$HAIL_VERSION" "0.2.18")
  echo "Version check 1: $TEST1"

  TEST2=$(compare_versions "$HAIL_VERSION" "0.2.23")
  echo "Version check 2: $TEST2"

  if [ "$HAIL_VERSION" != "master" ] && [[ "$TEST1" -eq 2 ]]; then
    if [ "$SPARK_VERSION" = "2.2.0" ]; then
      ./gradlew -Dspark.version="$SPARK_VERSION" shadowJar archiveZip
    else
      ./gradlew -Dspark.version="$SPARK_VERSION" -Dbreeze.version=0.13.2 -Dpy4j.version=0.10.6 shadowJar archiveZip
    fi
  elif [ "$HAIL_VERSION" = "master" ] || [[ "$TEST2" -eq 1 ]]; then
    make install-on-cluster HAIL_COMPILE_NATIVES=1 SPARK_VERSION="$SPARK_VERSION"
  else
    echo "Hail 0.2.19 - 0.2.23 builds are not possible due to incompatiable configurations resolved in 0.2.24."
    exit 1
  fi
}

function hail_install
{
  echo "Installing Hail locally"

  cat <<- HAIL_PROFILE > "$HAIL_PROFILE"
  export SPARK_HOME="/usr/lib/spark"
  export PYSPARK_PYTHON="python3.8"
  export PYSPARK_SUBMIT_ARGS="--conf spark.kryo.registrator=is.hail.kryo.HailKryoRegistrator --conf spark.serializer=org.apache.spark.serializer.KryoSerializer pyspark-shell"
  export PYTHONPATH="$HAIL_ARTIFACT_DIR/$ZIP_HAIL:\$SPARK_HOME/python:\$SPARK_HOME/python/lib/py4j-src.zip:\$PYTHONPATH"
HAIL_PROFILE

  TEST1=$(compare_versions "$HAIL_VERSION" "0.2.24")
  if [[ "TEST1" -eq 2 ]] && [[ "$SPARK_VERSION" < 2.4.1 ]]; then
    cp "$PWD/build/distributions/$ZIP_HAIL" "$HAIL_ARTIFACT_DIR"
  fi

  cp "$PWD/build/libs/$JAR_HAIL" "$HAIL_ARTIFACT_DIR"
}

function cleanup()
{
  rm -rf /root/.gradle
  rm -rf /home/ec2-user/hail
  rm -rf /root/hail
}

install_prereqs
hail_build
hail_install
cleanup
