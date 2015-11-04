#!/bin/bash

# 20150131, J. Sikkema, Tool that can mass update zonefiles and reloads them.

SEARCHPATH="/opt/named/db/"   # Named base dir
MGTZONE="/opt/named/db/PLACE.HOLDER"   # Special zonefile that governs multiple zones. (optional)
LOGFILE="/var/log/update.log"   # Bind logfile 
AUDIT='0'   # Keeps a logfile of all users using this tool. 0=no, 1=yes
AUDITFILE="/var/log/zoneupdate.log"   # Users logfile if AUDIT was set to '1'.
USERID="bind"   # The bind user ID.
INTERACTIVE_SEEKTIME="60"   # mtime in minutes when a zonefile was updated.
BULK_SEEKTIME="60"   # Same as above, but for non-interactive use.

#Set by getopts#
################
PRDRUN="1"
HEADLESS="0"
BULKMODE="0"
ZONEFILE=""
################

show_help () {
    echo -e "Usage: ${0##*/} [OPTION]... [FILE]...\n
This tool finds updated zonefiles, raises the serial and reloads them. -By default after interactive confirmation.\n
  -h -?         shows this help info.\n
  -b            headless bulk mode - finds multiple zonefiles, updates the serials and reloads them. -also overrides '-f' function\n
  -x 		headless single file mode - tries to find the last modified zonefile and perform a reload. -also overrides '-f' function\n
  -d 		runs the tool in dev mode - nothing is being modified only print what normally would be done. -this argument should preceed anything else.\n
  -f		specify zonefile manually - always use this flag as the last argument."
}

validate_env () {
    if [ ! "$USER" == "$USERID" ]; then
	bail_out "Error: You are not user "$USERID", exiting..."
    fi

    if [ -z auth_check=$(getent passwd "$USERID") ]; then
	bail_out "Error: user "$USERID" not in local passwd configuration, exiting..."
    fi

    if [ ! "$HOME" == "$SEARCHPATH" ]; then
	bail_out "Error: bind environment not ok, exiting..."
    fi

    if [ ! -d "$SEARCHPATH" ]; then
	bail_out "Error: "$SEARCHPATH" is not a valid directory, exiting..."
    fi

    if [ ! -r "$LOGFILE" ]; then
	bail_out "Error: cannot read "$LOGFILE", exiting..."
    fi

    if [ -z bind_process=$(pgrep -U bind -x named | tail -1) ]; then
	bail_out "Error: named service is not running, exiting..."
    fi
}

bail_out () {
    if [ "$PRDRUN" == '1' ]; then
        echo "$1"
        exit 1
    else
        echo "$1 - Dev mode active, not bailing out.."
    fi
}

accounting_user () {
    if [ "$AUDIT" == '0' ]; then
	return 0
    else
	who_am_i=`/usr/bin/who am i | awk '{print $1}'`
        echo "`date +%b' '%e' '%H:%M:%S' '`User "$who_am_i" updated zone: FILE>"$1" ORG>"$2" SERIAL>"$3" ARGS>"$4"" >> "$AUDITFILE"
    fi
}

get_single_serial () {
    if [ "$1" == "find_zone" ]; then
        zonefile=`find "$SEARCHPATH" -type f -executable -user "$USERID" -mmin -480 ! -iname '*.sh' ! -path "$MGTZONE" -not -path '*/\.*' -exec ls -1rt {} \+ | tail -1`
    else
        zonefile="$ZONEFILE"
    fi
    if [[ -r "$zonefile" ]] ; then
	    mgtzone=`echo "$zonefile" | grep -Ec "\.entries"`
	if [ "$mgtzone" -eq 0 ]; then
	    check_swpfile `readlink -f "$zonefile"`
	    serial=`grep -Ei ';serial|; serial' "$zonefile" | cut -d ';' -f 1 | tr -d "[:blank:]"`
	    if [[ -n "$serial" ]]; then
	        update_serial "$serial" "$zonefile"
	        zone_reload "$zonefile"
	    else
	        echo "Error: No serial found in "$zonefile" exiting..."
	        exit 1
	    fi	
	else
	    check_swpfile `readlink -f "$zonefile"`
	    zonefile=${zonefile%%.entries}
	    serial=`grep -Ei ';serial|; serial' "$zonefile" | cut -d ';' -f 1 | tr -d "[:blank:]"`
	     if [[ -n "$serial" ]]; then
	        update_serial "$serial" "$zonefile"
                zone_reload "$zonefile"
	        reload_mgt_zone='1'
	    else
	        echo "Error: No serial found in "$zonefile" exiting..."
	        exit 1
	    fi
	fi	 	
    else 
	echo  "Cannot stat "$zonefile" or no zonefile found, exiting..."
	exit 0
    fi
}

get_all_serials () {
    zonelist=`find "$SEARCHPATH" -type f -user "$USERID" -mmin -"$BULK_SEEKTIME" ! -iname '*.sh' ! -path "$MGTZONE" -not -path '*/\.*' -exec ls -1rt {} \+`
     if [[ -n "$zonelist" ]]; then
        for zonefile in $zonelist; do
            ZONEFILE="$zonefile"
            get_single_serial
        done
    else
        echo "No zonefiles found, exiting..."
        exit 0
    fi
}

get_all_serials_interactive () {
    zonelist=`find "$SEARCHPATH" -type f -executable -user "$USERID" -mmin -"$INTERACTIVE_SEEKTIME" ! -iname '*.sh' ! -path "$MGTZONE" -not -path '*/\.*' -exec ls -1rt {} \+`
    if [[ -n "$zonelist" ]]; then
        for zonefile in $zonelist; do
            ZONEFILE="$zonefile"
            echo "Found zonefile: "$ZONEFILE""; printf 'Update serial and reload zone? y/n [y]:'
            read arg
            case "${arg}" in
                y|\Y|"")
            	get_single_serial
            	;;
                n|\N)
            	continue
            	;;
                *)
            	echo "Please type 'y'=yes or 'n'=no, exiting..."
            	exit 0 
            	;;
            esac
        done
    else
        echo "No zonefiles found, exiting..."
        exit 0
    fi
}

check_swpfile () {
    if [ -f "$1" ]; then
        file_split="${1##*/}"; path_split="${1%/*}"; swpfile=".$file_split.swp"
        if [ -f "$path_split/$swpfile" ]; then
            echo "Swap file found: "$path_split/$swpfile" please properly close or remove this file first, exiting..."
       	    exit 1
        fi
    fi
}

update_serial () {
    current_date=`date +%Y%m%d%H`
    year_segment=${1:0:4}; month_segment=${1:4:2}; day_segment=${1:6:2}; hour_segment=${1:8:2}
    if [ "$year_segment" -gt `date +%Y` ]; then
        echo "Error: Serial "$1" in "$2": Year timestamp out of bounds ($year_segment), please modify serial and retransfer zone."
        exit 1
    elif [ "$month_segment" -gt '12' -o "$month_segment" -lt '01' ]; then
        echo "Error: Serial "$1" in "$2": Month timestamp out of bounds ($month_segment), please modify serial and retransfer zone."
        exit 1
    elif [ "$day_segment" -gt '32' -o "$day_segment" -lt '01' ]; then
        echo "Error: Serial "$1" in "$2": Day timestamp out of bounds ($day_segment), please modify serial and retransfer zone."
        exit 1 
    fi
    if [[ sanity_check="$(echo "$1" | grep -Ec '[[:alpha:]]')" -ge '1' ]]; then
        echo "Error: Serial "$1" in "$2" contains non numerical characters, exiting..."
        exit 1
    fi	
    if [[ ! character_check="$(echo "$1" | wc -c)" -eq '11' ]]; then
        echo "Error: Serial "$1" in "$2" contains an invalid number of characters, exiting..."
        exit 1
    fi
    if [[ duplicate_sr="$(grep -Fc "$1" "$2")" -gt '1' ]]; then
        echo ""$duplicate_sr" serial strings ($1) found in "$2", please correct manually."
        exit 1
    fi
    if [ "$hour_segment" -eq '23' ]; then
        raise_serial=`date +%Y%m%d%H -d '+1 days'`
        echo "Warning: serial ends with: "$hour_segment" If the serial is dated at the last day of the month, you have to update it manually" 	
        modify_serial "$1" "$raise_serial" "$2"
	updated_serial="$raise_serial"
    elif [ "$1" -ge "$current_date" ]; then
        raise_serial=$(expr "$1" + 1)
        modify_serial "$1" "$raise_serial" "$2"
	updated_serial="$raise_serial"
    else
        modify_serial "$1" "$current_date" "$2"
	updated_serial="$current_date"
    fi
}

modify_serial () {
    if [ "$PRDRUN" == '1' ]; then
	echo "Updating serial "$1" to "$2" in zonefile: "$3""
        sed -i 's/'"$1"'/'"$2"'/' "$3"
    else
        echo "We are in test mode, not updating serial "$1" to "$2" in zonefile: "$3""
    fi
}

reload_mgtzone_check () {
    if [ "$reload_mgt_zone" == '1' ]; then
        ZONEFILE="$MGTZONE"
        get_single_serial
        unset ZONEFILE
	reload_mgt_zone='0'
    fi
}

zone_reload () {
    rndc_string=`grep -Fic '\$origin' "$1"`
    if [ "$rndc_string" -ge 1 ]; then
        origin_directive=`grep -Fi '\$origin' "$1" | cut -d ' ' -f 2`
        rndc_reload "${origin_directive,,}"
    else
        echo "Error: origin directive not found in "$1", please reload manually."
    fi	
}

rndc_reload () {
    if [ "$PRDRUN" == '1' ]; then
        rndc reload "$1"
	accounting_user "$zonefile" "$1" "$updated_serial" "P="$PRDRUN"_H="$HEADLESS"_B="$BULKMODE"_M="$reload_mgt_zone""
	zone_array+=("$origin_directive")
    else
        echo "We are in test mode, not reloading zone "$1""
	zone_array+=("$origin_directive")
    fi
}

check_bind_errors () {
    log_date=`date +%d-%b-%Y`
    origin_regex="$(echo ${zone_array[@]} | sed s/' '/\|/g)"
    search_args="received control channel command|loaded serial|any newly configured zones are now loaded|loading configuration from|using default|reloading configuration succeeded|sizing zone task|reloading zones succeeded|flushing caches in all views succeeded"
    error_count=$(grep -Ev "$search_args" "$LOGFILE" | grep -Ei "$origin_regex" | grep -Fc "$log_date")
    if [ "$error_count" -gt 1 ]; then
        echo "Error: "$error_count" errors found in "$LOGFILE":"
        grep -F "$log_date" "$LOGFILE" | grep -Ei "$origin_regex"
    else
        if [ "$PRDRUN" == '1' ]; then 		
            echo "No errors found in "$LOGFILE":"
            grep -F "$log_date" "$LOGFILE" | grep -Ei "$origin_regex"
        else
            echo "No zones reloaded"
        fi
    fi
}

reload_mgt_zone='0' 

declare -a zone_array
   
while getopts "h?bdxf:" arg; do
    case "$arg" in
    h|\?)
        show_help
        exit 0
        ;;
    b)  BULKMODE='1'
	;;
    d) 	PRDRUN='0'
	;;
    x) 	###Headless mode###
	echo "Trying to find last edited zonefile, updating serial and perform an rndc reload..."
	validate_env
	get_single_serial "find_zone"
	reload_mgtzone_check
	check_bind_errors
	exit 0
	;;  	
    f)  ZONEFILE="$OPTARG"
        ;;
    esac
done

shift $((OPTIND-1))

[ "$1" = "--" ] && shift

if [ "$BULKMODE" == '0' ]; then
    validate_env
    if [ -n "$ZONEFILE" ]; then
        echo "Trying to update serial in "$ZONEFILE" and perform an rndc reload..."
        get_single_serial "$ZONEFILE"
    else
        echo "Trying to find last edited zonefiles within last "$INTERACTIVE_SEEKTIME" minutes, updating serials and reload them after confirmation..."
        get_all_serials_interactive
    fi
    reload_mgtzone_check
    check_bind_errors
elif [ "$BULKMODE" == '1' ]; then 
    validate_env
    echo "Trying to find last edited zonefiles within last "$BULK_SEEKTIME" minutes, updating serials and reload them..."
    get_all_serials
    reload_mgtzone_check
    check_bind_errors
fi

exit 0
