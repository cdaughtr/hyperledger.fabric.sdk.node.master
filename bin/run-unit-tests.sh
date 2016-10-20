#!/bin/bash
#
# run-unit-tests.sh
# Run the unit tests associated with the node.js client sdk
# Any arguments supplied to this script will be interpreted
# as a *js test file existing in
#
#  ${GOPATH}//src/github.com/hyperledger/fabric/sdk/node/test/unit
#
# By default all tests are run. Note that run-unit-tests.sh will
# only run tests that it knows about, since there are unique
# environmental prerequisites to many of the tests (including copying
# the fabric code into the chaincode directory). The 'case' statement
# in runTests() will need to be updated with the specific actions
# to perform for any new test that is added to the test/unit directory.
#
# The tests can be run against a local fabric network, or remote (such
# as Bluemix, HSBN, vLaunch, softLayer, etc.).
#
# The test will run 4 permutations of each test:
#    TLS-disabled - deployMode=Net
#    TLS-disabled - deployMode=Dev
#    TLS-enabled  - deployMode=Net
#    TLS-enabled  - deployMode=Dev
# While both 'dev' and 'net' mode are exercised, only
# 'net' mode will be executed when the network nodes
# are remote w/r/t to the host running the tests.
#
# There are six conditions that are fatal and will
# cause the tests to abort:
#   Local: 
#      membersrvc build fails
#      membersrvc fails to initialize
#      peer build fails
#      peer fails to initialize
#   Remote:
#      membersrvc is unreachable
#      peer is unreachable
#
# The following environment variables will determine the
# network resources to be tested
#    SDK_KEYSTORE - local directory under which user
#                   authentication data is stored
#    SDK_CA_CERT_FILE - CA certificate used to authenticate
#                       network nodes
#    SDK_CA_CERT_HOST - Expected host identity in server certificate
#                       Default is 'tlsca'
#    SDK_MEMBERSRVC_ADDRESS - ip address or hostname of membersrvc
#    SDK_PEER_ADDRESS - ip address or hostname of peer node under test;
#                       it is assumed that only one peer will contacted
#    SDK_TLS - Set to '1' (use TLS) or '0' (do not use TLS)
#              Note that if TLS is requested, a CA cert must be used.
#              The default certificate generated by membersrvc is the default:
#                 /var/hyperledger/production/.membersrvc/tlsca.cert
#              The run-unit-tests.sh script will run all unit tests
#              twice, one without TLS and one with TLS enabled
#
# Other environment variables that will be referenced by individual tests
#    SDK_DEPLOYWAIT - time (in seconds) to wait after sending deploy request
#    SDK_INVOKEWAIT - time (in seconds) to wait after sending invoke request
#    GRPC_SSL_CIPHER_SUITES - quoted, colon-delimited list of specific cipher suites 
#                             that node.js client sdk should propose.
#                             The default list is set in sdk/node/lib/hfc.js
#   SDK_DEFAULT_USER - User defined with 'registrar' authority. Default is 'WebAppAdmin'
#   SDK_DEFAULT_SECRET - Password for SDK_DEFAULT_USER. Defaults to 'DJY27pEnl16d'
#                        When running a local network, these are configured in the 
#                        membersrvc.yaml file. In the IBM Bluemix starter and HSBN
#                        networks, this password is generated dynamically and returned
#                        in the network credentials file.
#   SDK_KEYSTORE_PERSIST - Set to '0' will delete all previously generated auth 
#                                     enrollment data prior to running the tests
#                          Set to '1' keep the auth data from previous enrollments
#   SDK_CHAINCODE_PATH - the directory (relative to ${GOPATH}/src/) which contains
#                        the chaincode (and CA cert) to be deployed
#   SDK_CHAINCODE_ID -  the chaincode ID from a previous deployment. e.g. can be used
#                       to invoke/query previously-deployed chaincode
#
export NODE_PATH=${GOPATH}/src/github.com/hyperledger/fabric/sdk/node:${GOPATH}/src/github.com/hyperledger/fabric/sdk/node/lib:/usr/local/lib/node_modules:/usr/lib/nodejs:/usr/lib/node_modules:/usr/share/javascript
#export NODE_PATH=${GOPATH}/src/github.com/hyperledger/fabric/sdk/node:/usr/local/lib/node_modules:/usr/lib/nodejs:/usr/lib/node_modules:/usr/share/javascript

errorExit() {
   printf "%s...exiting\n" "$1"
   exit 1
}

resolvHost() {
   # simple 'host' or 'nslookup' doesn't work for 
   # /etc/host entries...attempt to resolve via ping
   local host="$1"
   ping -w2 -c1 "$host" | head -n1 | awk -F'[()]' '{print $2}'
}

isLocal() {
   # determine if the ca/peer instance in question
   # is running native/vagrant on this local machine,
   # or on a remote network. echo 'true' or 'false'
   # This permits constructions like
   #    $(isLocal <addr> <port>)
   # to return 0 (true) or 1 (false)
  
   local addr="$1"
   local port="$2"

   # assume remote
   local result="false"

   # if localhost, return true
   if test ${addr%%.*} = "127"; then
      result="true"
   else
      # search this machine for address
      ip addr list |
         awk -v s="$addr" -v rc=1 '
            $1=="inet" { gsub(/\/.*/,"",$2); if ($2==s) rc=0 } 
            END { exit rc }'
      if test $? -eq 0; then
         # address is local but still peer might be running in container
         # if docker-proxy is not running this instance, return true 
         sudo netstat -tlpn | grep "$port" |
            awk -F '/' '{print $NF}'| grep -q proxy
         test $? = 0 || result="true"
      fi
   fi
   echo "$result"
   return 0
}

isReachable() {
   # a test to see if there is a listener on
   # specified host:port
   # netcat would be *far* simpler:
   #    nc -nzvt host port
   # but not guaranteed to be installed
   # so use python, since it is ubiquitious
   local host="$1"
   local port="$2"
   test -z "$host" -o -z "$port" && return 1

   python - <<END
import socket
import sys
import os
remoteServer =  "$host"
port         = int("$port");
remoteServerIP  = socket.gethostbyname(remoteServer)
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
result = sock.connect_ex((remoteServerIP, port))
sock.close()
os._exit(result)
END
}

# initialization & cleanup
init() {
   # Initialize variables
   NODE_ERR_CODE=0
   FABRIC=$GOPATH/src/github.com/hyperledger/fabric
   LOGDIR=/tmp/node-sdk-unit-test
   MSEXE=$FABRIC/build/bin/membersrvc
   # user did not go through the normal build process, build in place
   test ! -f "$MSEXE" && MSEXE="$FABRIC/membersrvc/membersrvc"
   MSLOGFILE=$LOGDIR/membersrvc.log
   PEEREXE=$FABRIC/build/bin/peer
   # user did not go through the normal build process, build in place
   test ! -f "$PEEREXE" & PEEREXE="$FABRIC/peer/peer"
   PEERLOGFILE=$LOGDIR/peer.log
   UNITTEST=$GOPATH/src/github.com/hyperledger/fabric/sdk/node/test/unit
   EXAMPLES=$FABRIC/examples/chaincode/go
   TIMEOUT="15"

   # Run locally by default
   : ${SDK_MEMBERSRVC_ADDRESS:="localhost:7054"}
   : ${SDK_PEER_ADDRESS:="localhost:7051"}

   # extract hostname/ip and port
   caHost="${SDK_MEMBERSRVC_ADDRESS%:*}"
   caPort="${SDK_MEMBERSRVC_ADDRESS#*:}"
   peerHost="${SDK_PEER_ADDRESS%:*}" 
   peerPort="${SDK_PEER_ADDRESS#*:}" 
   caAddr="$(resolvHost $caHost)"
   peerAddr="$(resolvHost $peerHost)"

   # determine if addresses are local to host where the sdk is running
   caAddrIsLocal=$( isLocal $caAddr $caPort )
   peerAddrIsLocal=$( isLocal $peerAddr $peerPort )

   # if not running locally, exit if no remote TCP listeners
   # are found for the specified address and port
   if ! $($caAddrIsLocal) ; then
      isReachable "$caAddr" "$caPort" ||
         errorExit "membersrvc ($caHost:$caPort) unreachable"
   fi
   if ! $($peerAddrIsLocal) ; then
      isReachable "$peerAddr" "$peerPort" ||
         errorExit "peer ($peerAddr:$peerPort) unreachable"
   fi
   
   # Set logging levels to enhance debugging
   export MEMBERSRVC_CA_LOGGING_TRACE=1
   export MEMBERSRVC_CA_LOGGING_SERVER="debug"
   export MEMBERSRVC_CA_LOGGING_CA="debug"
   export MEMBERSRVC_CA_LOGGING_ECA="debug"
   export MEMBERSRVC_CA_LOGGING_ECAP="debug"
   export MEMBERSRVC_CA_LOGGING_ECAA="debug"
   export MEMBERSRVC_CA_LOGGING_ACA="debug"
   export MEMBERSRVC_CA_LOGGING_ACAP="debug"
   export MEMBERSRVC_CA_LOGGING_TCA="debug"
   export MEMBERSRVC_CA_LOGGING_TCAP="debug"
   export MEMBERSRVC_CA_LOGGING_TCAA="debug"
   export MEMBERSRVC_CA_LOGGING_TLSCA="debug"
   export CORE_LOGGING_LEVEL="debug"
   export CORE_LOGGING_PEER="debug"
   export CORE_LOGGING_NODE="debug"
   export CORE_LOGGING_NETWORK="debug"
   export CORE_LOGGING_CHAINCODE="debug"
   export CORE_LOGGING_VERSION="debug"

   # Always run peer with security and privacy enabled
   export CORE_SECURITY_ENABLED=true
   export CORE_SECURITY_PRIVACY=true

   # Increase timeout slightly for insurance
   # unless explicitly set
   : ${SDK_DEPLOYWAIT:=40}
   : ${SDK_INVOKEWAIT:=15}
   export SDK_DEPLOYWAIT SDK_INVOKEWAIT

   # Run the membersrvc with the Attribute Certificate Authority enabled
   export MEMBERSRVC_CA_ACA_ENABLED=true

   export SDK_MEMBERSRVC_ADDRESS SDK_PEER_ADDRESS SDK_KEYSTORE_PERSIST 

   # Run all tests by default
   : ${TEST_SUITE:="$(ls $UNITTEST/*.js)"}

   if $($caAddrIsLocal); then
      # If the executables don't exist where they belong, build them now in place
      if test ! -f $MSEXE ; then
         cd $FABRIC/membersrvc
         echo "Building membersrvc..."
         go build || errorExit "Build of membersrvc failed."
      fi
      # Clean up if anything remaining from previous run
      stopMemberServices
   fi

   if $($peerAddrIsLocal); then
      # If the executables don't exist where they belong, build them now in place
      if test ! -f $PEEREXE ; then
         cd $FABRIC/peer
         echo "Building peer..."
         go build || errorExit "Build of peer failed."
      fi
      # Clean up if anything remaining from previous run
      stopPeer
   fi

   # do not delete the authentication data if this is set
   test "$SDK_KEYSTORE_PERSIST" != "1" &&
      rm -rf /var/hyperledger/production /tmp/*keyValStore* 

   rm -rf $LOGDIR
   mkdir $LOGDIR
}

pollServer() {
   local app="$1"
   local host="$2"
   local port="$3"
   local rc=1
   local starttime=$(date +%s)

   # continue to poll host:port until
   # we either get a response, or reach timeout
   while test "$(($(date +%s)-starttime))" -lt "$TIMEOUT" -a $rc -ne 0
   do  
      sleep 1
      printf "\r%s%03d" "Waiting for $app start on $host:$port ..." "$now"
      isReachable "$host" "$port"
      rc=$?
   done
   echo ""
   return $rc
}

startMemberServices() {
   local rc=0 

   if test "$SDK_TLS" = "1"; then
      export MEMBERSRVC_CA_SERVER_TLS_CERT_FILE=$SDK_CA_CERT_FILE 
      export MEMBERSRVC_CA_SERVER_TLS_KEY_FILE=$SDK_CA_KEY_FILE 
      export MEMBERSRVC_CA_SERVER_TLS_CERTFILE=$SDK_CA_CERT_FILE 
      export MEMBERSRVC_CA_SERVER_TLS_KEYFILE=$SDK_CA_KEY_FILE
   else 
      unset MEMBERSRVC_CA_SERVER_TLS_CERT_FILE
      unset MEMBERSRVC_CA_SERVER_TLS_KEY_FILE
      unset MEMBERSRVC_CA_SERVER_TLS_CERTFILE
      unset MEMBERSRVC_CA_SERVER_TLS_KEYFILE
   fi

   startProcess "$MSEXE" "$MSLOGFILE" "member services" &&
      pollServer membersrvc "$caAddr" "$caPort" || let rc+=1

   # it takes a little time to create the crypto artifacts
   if test "$SDK_TLS" = "1"; then
      sleep 5
      cp $SDK_CA_CERT_FILE $FABRIC || let rc+=1
      cp $SDK_CA_KEY_FILE  $FABRIC || let rc+=1
   fi

   return $rc
}

stopMemberServices() {
   killProcess $MSEXE
}

startPeer() {
   local rc=0

   if test "$SDK_TLS" = "1"; then
      export CORE_PEER_TLS_ENABLED=true 
      export CORE_PEER_TLS_CERT_FILE=$SDK_CA_CERT_FILE 
      export CORE_PEER_TLS_KEY_FILE=$SDK_CA_KEY_FILE
      export CORE_PEER_TLS_SERVERHOSTOVERRIDE=tlsca
      export CORE_PEER_PKI_TLS_ENABLED=true 
      export CORE_PEER_PKI_TLS_ROOTCERT_FILE=$SDK_CA_CERT_FILE  
      export CORE_PEER_PKI_TLS_SERVERHOSTOVERRIDE=tlsca
   else
      unset CORE_PEER_TLS_ENABLED
      unset CORE_PEER_TLS_CERT_FILE
      unset CORE_PEER_TLS_KEY_FILE
      unset CORE_PEER_TLS_SERVERHOSTOVERRIDE
      unset CORE_PEER_PKI_TLS_ENABLED
      unset CORE_PEER_PKI_TLS_ROOTCERT_FILE
      unset CORE_PEER_PKI_TLS_SERVERHOSTOVERRIDE
   fi

   if test "$SDK_DEPLOY_MODE" = "net"; then
      startProcess "$PEEREXE node start" "$PEERLOGFILE" "peer" || let rc+=1
   else
      startProcess "$PEEREXE node start --peer-chaincodedev" "$PEERLOGFILE" "peer" || let rc+=1
   fi
   test $rc -eq 0 && pollServer peer "$peerAddr" "$peerPort" # poll until peer is up
   sleep 3

   return $rc
}

stopPeer() {
   killProcess $PEEREXE
}

# $1 is the name of the example to prepare
preExample() {
  local chaincodeSrc="$1"
  local chaincodeName="$2"
  local rc=0

  if test "$SDK_DEPLOY_MODE" = "net"; then
    prepareExampleForDeployInNetworkMode "$chaincodeSrc"
  else
    startExampleInDevMode "$chaincodeSrc" "$chaincodeName"
  fi
  rc+=$?
}

# $1 is the name of the example to stop
postExample() {
  local chaincode="$1"
  if test "$SDK_DEPLOY_MODE" = "net"; then
    echo "finished $chaincode"
  else
    echo "stopping $chaincode"
    stopExampleInDevMode $chaincode
  fi
}

# $1 is name of example to prepare on disk
prepareExampleForDeployInNetworkMode() {
   local chaincodeSrc="$1"
   local rc=0

   DSTDIR=${GOPATH}/src/github.com/${chaincodeSrc}
   SRCDIR="${EXAMPLES}/${chaincodeSrc}"

   if test -d $DSTDIR; then
      echo "$DSTDIR already exists"
   elif test ! -d $SRC_DIR; then
         echo "ERROR: directory does not exist: $SRCDIR"
         rc=$((rc+1))
   else
      mkdir $DSTDIR
      cd $DSTDIR
      cp $SRCDIR/${chaincodeSrc}.go .
      test "$SDK_TLS" = "1" && cp "$SDK_CA_CERT_FILE" .
      mkdir -p vendor/github.com/hyperledger
      cd vendor/github.com/hyperledger
      echo "copying github.com/hyperledger/fabric; please wait ..."
      # git clone https://github.com/hyperledger/fabric > /dev/null
      cp -r $FABRIC .
      cp -r fabric/vendor/github.com/op ..
      cd ../../..
   
      echo "Building chaincode..."
      go build
      rc+=$?
   fi 

   return $rc
}

# $1 is the name of the sample to start
startExampleInDevMode() {
   local chaincodeSrc="$1"
   local rc=0
   export CORE_CHAINCODE_ID_NAME=$2
   export CORE_PEER_ADDRESS=localhost:7051

   SRCDIR=${EXAMPLES}/${chaincodeSrc}

   if test ! -d $SRC_DIR; then
      echo "ERROR: directory does not exist: $SRCDIR"
      rc=1
   else
      EXE=${SRCDIR}/${chaincodeSrc}
      if test ! -f $EXE; then
         cd $SRCDIR
         go build
         rc=$?
      fi

      test "$rc" = 0 && startProcess "$EXE" "${EXE}.log" "$chaincodeSrc"
      let rc+=$?
   fi

   return $rc
}

# $1 is the name of the sample to stop
stopExampleInDevMode() {
   echo "killing $1"
   killProcess $1
}

runRegistrarTests() {
   local rc=0
   echo "BEGIN running registrar tests ..."
   node $UNITTEST/registrar.js
   rc=$?
   echo "END running registrar tests"
   return $rc
}

runMemberApi() {
   local rc=0
   echo "BEGIN running member-api tests ..."
   node $UNITTEST/member-api.js
   rc=$?
   echo "END running member-api tests"
   return $rc
}

runChainTests() {
   local rc=0
   echo "BEGIN running chain-tests ..."
   preExample chaincode_example02 mycc1
   if test $? -eq 0; then
      node $UNITTEST/chain-tests.js
      rc=$?
      postExample chaincode_example02
   else
      echo "setup failed"
      let rc+=1
   fi
   echo "END running chain-tests"
   return $rc
}

runAssetMgmtTests() {
   local rc=0
   echo "BEGIN running asset-mgmt tests ..."
   preExample asset_management mycc2
   if test $? -eq 0; then
      node $UNITTEST/asset-mgmt.js
      rc=$?
      postExample asset_management
   else
      echo "setup failed"
      let rc+=1
   fi
   echo "END running asset-mgmt tests"
   return $rc
}

runAssetMgmtWithRolesTests() {
   local rc=0
   echo "BEGIN running asset management with roles tests ..."
   preExample asset_management_with_roles mycc3
   if test $? -eq 0; then
      node $UNITTEST/asset-mgmt-with-roles.js
      rc=$?
      postExample asset_management_with_roles
   else
      echo "setup failed"
      let rc+=1
   fi
   echo "END running asset management with roles tests"
   return $rc
}

runAssetMgmtWithDynamicRolesTests() {
   local rc=0
   echo "BEGIN running asset management with dynamic roles tests ..."
   preExample asset_management_with_roles mycc4
   if test $? -eq 0; then
      node $UNITTEST/asset-mgmt-with-dynamic-roles.js
      rc=$?
      echo "RC:" $rc
      postExample asset_management_with_roles
   else
      echo "setup failed"
      let rc+=1
   fi
   echo "END running asset management with dynamic roles tests"
   return $rc
}
# start process
#   $1 is executable path with any args
#   $2 is the log file
#   $3 is string description of the process
startProcess() {
   local cmd="$1"
   local log="$2"
   local proc="$3"

   $cmd >> $log 2>&1&
   PID=$!
   sleep 2
   kill -0 $PID > /dev/null 2>&1
   if test $? -eq 0; then
      echo "$proc is started"
   else
      echo "ERROR: $proc failed to start; see $log"
      return 1
   fi
}

# kill a process
#   $1 is the executable name
killProcess() {
   local proc="$1"
   PID=$(ps -ef | awk -v s="$proc" '$0~s && $8!="awk" {print $2}')
   if test -n "$PID"; then
      echo "killing PID $PID running $proc ..."
      kill -9 $PID
   fi
}

# Run tests
runTests() {
   local TestsToBeRun="$1"
   local rc=0

   echo "Begin running tests in $SDK_DEPLOY_MODE mode ..."
   # restart peer
   if $($peerAddrIsLocal); then 
      stopPeer
      startPeer || errorExit "Start peer failed."
   fi
   
   for Test in $TestsToBeRun; do
      # echo "HIT <ENTER> TO RUN NEXT TEST...."
      # read x
      case "${Test##*/}" in 
                    "registrar.js") runRegistrarTests ;;
                  "chain-tests.js") runChainTests     ;;
                   "asset-mgmt.js") runAssetMgmtTests ;;
                   "member-api.js") runMemberApi ;;
"asset-mgmt-with-dynamic-roles.js") if test "$SDK_TLS" = 0; then
                                       runAssetMgmtWithDynamicRolesTests
                                    else
                                       echo "FAB-392; SKIPPING AssetMgmtWithDynamicRolesTests"
                                    fi ;;
        # bug...FAB-392 - ACA combined with TLS fails - re-enable this for all tests when closed
        "asset-mgmt-with-roles.js") if test "$SDK_TLS" = 0; then
                                       runAssetMgmtWithRolesTests
                                    else
                                       echo "FAB-392; SKIPPING AssetMgmtWithRolesTests" 
                                    fi ;;
                                 *) echo "NO case statement for ${Test##*/}, skipping..." ;;
      esac
      if test $? -ne 0; then
         echo "*******  ${Test##*/} failed!  *******"
         let NODE_ERR_CODE=$((NODE_ERR_CODE+1))
      fi
      echo "**************************************************************"
      echo ""
      echo ""
   done

   echo "End running tests in $SDK_DEPLOY_MODE mode"
   sleep 5
}

main() {
   # Initialization
   echo "Initilizing environment..."
   init
   {
      printf "%s -----> Beginning nodejs SDK UT tests...\n" "$(date)"
      for t in ${TEST_SUITE[*]}; do
         echo ${t##*/} | sed 's/^/   /'
      done
       
      # Start member services
      for tlsEnabled in 0 1; do 
         export SDK_TLS=$tlsEnabled
         test "$SDK_TLS" = 0 && echo "Running NON-TLS-enabled tests..." || echo "Running TLS-enabled tests..."
      
         if test "$SDK_TLS" = "1"; then
            : ${SDK_CA_CERT_FILE:="/var/hyperledger/production/.membersrvc/tlsca.cert"}
            : ${SDK_CA_KEY_FILE:="/var/hyperledger/production/.membersrvc/tlsca.priv"}
            export SDK_CA_CERT_FILE
         else 
            export MEMBERSRVC_CA_ACA_ENABLED=true
         fi
      
         $($caAddrIsLocal) && startMemberServices
         test $? -eq 0 || errorExit "Failed to start membersrvc"
      
        # Run tests in network mode
        SDK_DEPLOYWAIT=40
        SDK_INVOKEWAIT=15
        export SDK_DEPLOY_MODE='net'
        runTests "$TEST_SUITE"
      
        # Run tests in dev mode
        SDK_DEPLOYWAIT=10
        SDK_INVOKEWAIT=5 
        if $($peerAddrIsLocal); then
           export SDK_DEPLOY_MODE='dev'
           runTests "$TEST_SUITE"
        fi
         
         # Stop peer and member services
         $($peerAddrIsLocal) && stopPeer
         $($caAddrIsLocal) && stopMemberServices

      # do not delete the authentication data if this is set
      test "$SDK_KEYSTORE_PERSIST" != "1" &&
      rm -rf /var/hyperledger/production /tmp/*keyValStore* 

      done
      printf "\n%s\n" "${NODE_ERR_CODE}"
   } 2>&1 | tee $LOGDIR/log
}

TEST_SUITE="$@"
main
NODE_ERR_CODE=$(sed -n '$p' $LOGDIR/log | awk '{print $NF}')
echo "exit code: $NODE_ERR_CODE"
printf "%s " $(date)
test "$NODE_ERR_CODE" -eq 0 && echo "UT tests PASSED" || echo "UT tests FAILED"
exit $NODE_ERR_CODE
