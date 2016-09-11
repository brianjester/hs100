#!/bin/bash

set -o errexit

##
#  Switch the TP-LINK HS100 wlan smart plug on and off, query for status
#  Tested with firmware 1.0.8
#
#  Credits to Thomas Baust for the query/status/emeter commands
#
#  Author George Georgovassilis, https://github.com/ggeorgovassilis/linuxscripts

# encoded (the reverse of decode) commands to send to the plug

# encoded {"system":{"set_relay_state":{"state":1}}}
payload_on="AAAAKtDygfiL/5r31e+UtsWg1Iv5nPCR6LfEsNGlwOLYo4HyhueT9tTu36Lfog=="

# encoded {"system":{"set_relay_state":{"state":0}}}
payload_off="AAAAKtDygfiL/5r31e+UtsWg1Iv5nPCR6LfEsNGlwOLYo4HyhueT9tTu3qPeow=="

# encoded { "system":{ "get_sysinfo":null } }
payload_query="AAAAI9Dw0qHYq9+61/XPtJS20bTAn+yV5o/hh+jK8J7rh+vLtpbr"

# the encoded request { "emeter":{ "get_realtime":null } }
payload_emeter="AAAAJNDw0rfav8uu3P7Ev5+92r/LlOaD4o76k/6buYPtmPSYuMXlmA=="

# BSD base64 decode on osx has different options
# BSD od (octal dump) on osx has different options
od_offset=4
case $OSTYPE in
   darwin*)
      BASE64DEC="-D"
      ODOPTS="-j $od_offset -A n -t u1"
      ;;
   linux*)
      BASE64DEC="-d"
      ODOPTS="--skip-bytes=$od_offset --address-radix=n -t u1 --width=9999"
      ;;
esac

# netcat options
timeout=2
NCOPTS=""
#NCOPTS+='-v' # verbose
NCOPTS+=" -G $timeout"

# tools

error(){
   echo >&2 "$@"
   exit 2
}

quiet(){
   $@ >/dev/null 2>&1
}

mac_from_ip()
{
    # if you've contacted an IP recently, the arp cache has juicy info
    local ip=$1
    mac=$(arp -a \
            | grep "($ip)" \
            | egrep -o '(([0-9a-fA-F]{1,2}:){5}[0-9a-fA-F]{1,2})' )
    [ -z "$mac" ] && { echo 2>&1 "arp didn't find a MAC for $ip!"; return 1; }
    echo $mac
}

unique_hostname()
{
    # given a prefix and a MAC for a host, construct a unique name for the host
    local prefix=$1;    [ -n $prefix ] || return 1
    local mac=$2;       [ -n $mac ] || return 1

    # use the first 7 characters of the shasum as unique ID
    hash=$(echo $mac | shasum)
    hs100host=hs100${hash:0:7}
    echo $hs100host
}

host_entry()
{
    host=$1
    ip=$2
    printf "${hs100ip}\t${hs100host}\n" >> /etc/hosts
    echo plug $host has ip $hs100ip
}

check_dependency()
{
    dep=$1
    message=$2
    quiet command -v "$dep" || error "$message"
}

check_dependencies() {
    check_dependency nc \
       "The nc programme for sending data over the network isn't" \
       "in the path, communication with the plug will fail"
    check_dependency base64 \
       "The base64 programme for decoding base64 encoded strings isn't" \
       "info the path, decoding of payloads will fail"
    check_dependency od \
        "The od programme for converting binary data to numbers isn't" \
        "in the path, the status and emeter commands will fail"
    check_dependency shasum \
        "The shasum programme for hashing strings isn't"\
        "in the path, the sudo discover command will fail"
}

usage() {
   echo "Usage: $0 [-i IP] [-p PORT] COMMAND"
   echo "where COMMAND is one of: ${commands[@]}"
   exit 1
}

check_arguments() {
   check_arg() {
      name="$1"
      value="$2"
      if [ -z "$value" ]; then
         echo "missing argument $name"
         usage
      fi
   }
   check_arg "ip" $ip
   check_arg "port" $port
   check_arg "command" $cmd
}

# Check for a single string in a list of space-separated strings.
# e.g. has "foo" "foo bar baz" is true, but has "f" "foo bar baz" is not.
# from https://chromium.googlesource.com/chromiumos/platform/crosutils/+/master/common.sh
has()
{ [[ " ${*:2} " == *" $1 "* ]]; }

check_command()
{ has "$1" "$commands"; }

send_to_plug() {
   ip="$1"
   port="$2"
   payload="$3"
   if ! echo -n "$payload" | base64 ${BASE64DEC} | nc $NCOPTS $ip $port
   then
      echo couldn''t connect to $ip:$port, nc failed with exit code $?
   fi
}

decode(){
   code=171
   input_num=`od $ODOPTS`
   IFS=' ' read -r -a array <<< "$input_num"
   args_for_printf=""
   for element in "${array[@]}"
   do
      output=$(( $element ^ $code ))
      args_for_printf="$args_for_printf\x$(printf %x $output)"
      code=$element
   done
   printf "$args_for_printf"
}

query_plug(){
   payload=$1
   send_to_plug $ip $port "$payload" | decode
}

# plug commands
cmd_discover(){
    myip=`./myip.sh`
    subnet=${myip%%.[0-9]}.0-255
    hs100ip=$(nmap -p ${port} --open ${subnet} \
                | grep 'Nmap scan report for' \
                | egrep -o '(([0-9]{1,3}\.){3}[0-9]{1,3})' ) \
        || error "Could not find any hs100 plugs"

    # if we can't write this to /etc/hosts, echo what we found and quit
    if ! [ -w /etc/hosts ]
    then
        echo HS100 plugs found: $hs100ip
        return 0
    fi

    # remove existing hs100* hosts entries
    sed -i bak /hs100/d /etc/hosts

    if [[ ${#hs100ip[@]} = 1 ]]
    then
        host_entry hs100 $hs100ip
        return 0
    fi

    # multiple HS100 plugs on the network, hash MAC address for unique hostname
    for ip in ${hs100ip[@]}
    do
        # since we just hit it with nmap, it should be in the arp cache
        mac=`mac_from_ip $hs100ip`
        hs100host=`unique_hostname hs100 $mac`
        host_entry $hs100host $hs100ip
    done
    return 0
}

cmd_print_plug_relay_state(){
   output=`send_to_plug $ip $port "$payload_query" | decode | egrep -o 'relay_state":[0,1]' | egrep -o '[0,1]'`
   if [[ $output -eq 0 ]]; then
     echo OFF
   elif [[ $output -eq 1 ]]; then
     echo ON
   else
     echo Couldn''t understand plug response $output
   fi
}

cmd_print_plug_status(){
   query_plug "$payload_query"
}

cmd_print_plug_consumption(){
   query_plug "$payload_emeter"
}

cmd_switch_on(){
   send_to_plug $ip $port $payload_on > /dev/null
}

cmd_switch_off(){
   send_to_plug $ip $port $payload_off > /dev/null
}

commands=" on off check status emeter discover "

# run the Main progamme, if we are not being sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then

# process args with getopt(1). See `man getopt`
args=`getopt qvi:p: $*` || { usage; exit 1; }
set -- $args

for i #in $@
do
    case "$i" in
    -q) opt_quiet=yes; shift;;
    -v) set -o xtrace; shift;;
    -i) ip=$2; shift; shift;;
    -p) port=$2; shift; shift;;
    --) shift; break;;
    #*)  error "Getopt broke! Found $i"
    esac
done

: ${ip=hs100}
: ${port=9999}
cmd=$1

check_dependencies
check_arguments
check_command $cmd

case "$cmd" in
  discover) cmd_discover;;
  on)       cmd_switch_on;;
  off)      cmd_switch_off;;
  check)    cmd_print_plug_relay_state;;
  status)   cmd_print_plug_status;;
  emeter)   cmd_print_plug_consumption;;
  *)        usage;;
esac

fi # end main program
