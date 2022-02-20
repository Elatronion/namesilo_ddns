#!/bin/bash

##APIKEY obtained from Namesilo:
APIKEY=$1
##TYPE (A, TXT)
TYPE=$2
##Domain name (example.com)
DOMAIN=$3
##Host name / subdomain (www). Optional.
HOST=$4

if [ -z $HOST ]
then
	URL=$DOMAIN
else
	URL=$HOST.$DOMAIN
fi

## Do not edit lines below ##

##Saved history pubic IP from last check
IP_FILE="/var/tmp/MyPubIP_$HOST$DOMAIN"

##Time IP last updated or 'No IP change' log message output
IP_TIME="/var/tmp/MyIPTime_$HOST$DOMAIN"

##How often to output 'No IP change' log messages
NO_IP_CHANGE_TIME=86400

##Response from Namesilo
RESPONSE="/tmp/namesilo_response_$HOST$DOMAIN.xml"

##Choose randomly which OpenDNS resolver to use
RESOLVER=resolver$(echo $((($RANDOM%4)+1))).opendns.com
##Get the current public IP using DNS
CUR_IP="$(dig +short myip.opendns.com @$RESOLVER)"
ODRC=$?

## Try google dns if opendns failed
if [ $ODRC -ne 0 ]; then
   logger -t IP.Check -- IP Lookup at $RESOLVER failed!
   sleep 5
##Choose randomly which Google resolver to use
   RESOLVER=ns$(echo $((($RANDOM%4)+1))).google.com
##Get the current public IP 
   IPQUOTED=$(dig TXT +short o-o.myaddr.l.google.com @$RESOLVER)
   GORC=$?
## Exit if google failed
   if [ $GORC -ne 0 ]; then
     logger -t IP.Check -- IP Lookup at $RESOLVER failed!
     exit 1
   fi
   CUR_IP=$(echo $IPQUOTED | awk -F'"' '{ print $2}')
fi

##Check file for previous IP address
if [ -f $IP_FILE ]; then
  KNOWN_IP=$(cat $IP_FILE)
else
  KNOWN_IP=
fi

##See if the IP has changed
if [ "$CUR_IP" != "$KNOWN_IP" ]; then
  echo $CUR_IP > $IP_FILE
  logger -t IP.Check -- Public IP changed to $CUR_IP from $RESOLVER

  ## Update DNS record in Namesilo:
  curl -s "https://www.namesilo.com/api/dnsListRecords?version=1&type=xml&key=$APIKEY&domain=$DOMAIN" > $DOMAIN.xml 

  ## Only get first record, (fixes crash if multiple records exist)
  RECORD_ID=`xmllint --xpath "//namesilo/reply/resource_record/record_id[../host/text() = '$URL' ]" $DOMAIN.xml | grep -oP '(?<=<record_id>).*?(?=</record_id>)'`
  stringarray=($RECORD_ID)
  RECORD_ID=${stringarray[0]} ## TODO: Allow for multiple records to be considered

  ## RECORD_ID is equaled to every domain dns with subdomain, sepereated by a space, only works with one now.
if [ "$TYPE" == "A" ]
then
	curl -s "https://www.namesilo.com/api/dnsUpdateRecord?version=1&type=xml&key=$APIKEY&domain=$DOMAIN&rrid=$RECORD_ID&rrhost=$HOST&rrvalue=$CUR_IP&rrttl=3600" > $RESPONSE
elif [ "$TYPE" == "TXT" ]
then	
	curl -s "https://www.namesilo.com/api/dnsUpdateRecord?version=1&type=xml&key=$APIKEY&domain=$DOMAIN&rrid=$RECORD_ID&rrhost=$HOST&rrvalue=v=spf1%20a%20mx%20ptr%20ip4:$CUR_IP%20~all&rrttl=3600" > $RESPONSE
fi

	RESPONSE_CODE=`xmllint --xpath "//namesilo/reply/code/text()"  $RESPONSE`
       case $RESPONSE_CODE in
       300)
         date "+%s" > $IP_TIME
         logger -t IP.Check -- Update success. Now $URL IP address is $CUR_IP;;
       280)
         logger -t IP.Check -- Duplicate record exists. No update necessary;;
       *)
         ## put the old IP back, so that the update will be tried next time
         echo $KNOWN_IP > $IP_FILE
         logger -t IP.Check -- DDNS update failed code $RESPONSE_CODE!;;
     esac

else
  ## Only log all these events NO_IP_CHANGE_TIME after last update
  [ $(date "+%s") -gt $((($(cat $IP_TIME)+$NO_IP_CHANGE_TIME))) ] &&
    logger -t IP.Check -- NO IP change from $RESOLVER &&
    date "+%s" > $IP_TIME
fi

exit 0
