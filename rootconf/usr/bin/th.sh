if [[ $# -lt 2 ]]; then
	echo "Usage: $(basename $0) {<interface>|[<family>/]<counter>|<flags>}"
        echo " - counter is a name of a counter that should be shown"
        echo " - family is what type of counter it is. Possible families are:"
	echo "    - ETH/name -- name of the counter in ethtool output"
        echo "      this is the default"
	echo "    - IPL/jqpath -- path inside stats64 object to get a counter"
	echo "      in the output of ip -s -j link show dev <if>"
        echo "    - ING/jqpath -- path inside stats object to get a counter"
	echo "      in the output of tc -s -j flow show dev <if> ingress"
        echo "    - EGR/jqpath -- likewise for egress"
        echo
        echo " - flags change the way that following counters will be shown"
        echo "   P: the counter is in packets (that's the default)"
        echo "   B: the counter is in bytes"
        echo "   1: the counter is unitless"
        echo "   Bb: the counter is bytes, but show it in bits"
        echo "   uS: the counter is in microseconds"
        echo
        echo "   N: the value is shown as-is"
        echo "   T: counter baseline value is updated on every tick"
        echo "      and the shown value is per second increment"
        echo "   O: counter baseline value is updated once when the"
        echo "      tool is started. Thus the value shown is how much"
        echo "      has the counter increased since the tool was started"
        echo
        echo "   -s <time> changes the amount of sleep between ticks"
        echo "             The default is 1s"
	echo
	echo "e.g.: $(basename $0) sw1p6 rx_octets_prio_1 sw1p7 rx_octets_prio_2 sw1p10 rx_octets_prio_1 rx_octets_prio_2 B: N: sw1p9 tc_transmit_queue_tc_1 tc_transmit_queue_tc_2 T: IPL/tx.bytes ING/actions[0].stats.bytes"
	exit 1
fi

declare -a COUNTERS

type=P
update=tick
sleep=1
kind=relative
if=
while [[ $# -gt 0 ]]; do
    arg=$1; shift
    if [[ $arg == "N:" ]]; then
	update=never
        kind=absolute
	continue
    elif [[ $arg == "O:" ]]; then
	update=once
        kind=absolute
	continue
    elif [[ $arg == "T:" ]]; then
	update=tick
        kind=relative
	continue
    elif [[ $arg == "Bb:" ]]; then
	type=Bb
	continue
    elif [[ $arg == "B:" ]]; then
	type=B
	continue
    elif [[ $arg == "P:" ]]; then
	type=P
	continue
    elif [[ $arg == "1:" ]]; then
	type=1
	continue
    elif [[ $arg == "uS:" ]]; then
	type=uS
	continue
    elif [[ $arg == "-s" ]]; then
	sleep=$1; shift
	continue
    elif ip l sh dev $arg &> /dev/null; then
	if=$arg
	continue
    elif [[ -z $if ]]; then
	echo "'$arg' is not an interface, so it must be a counter"
	echo "but no interface has been selected"
	exit 1
    fi

    counter=$arg
    COUNTERS[${#COUNTERS[@]}]="type=$type update=$update \
                               kind=$kind if=$if counter=$arg"
done

humanize()
{
	local value=$1; shift
	local suffix=$1; shift
	local -a prefix=("$@")

	for unit in "${prefix[@]}" "" K M G; do
		if (($(echo "$value < 1024" | bc))); then
			break
		fi

		value=$(echo "scale=1; $value / 1024" | bc)
	done

	echo "$value${unit}${suffix}"
}

rate()
{
	local t0=$1; shift
	local t1=$1; shift
	local interval=$1; shift

	echo "($t1 - $t0) / $interval" | bc
}

ethtool_stats_get()
{
	local dev=$1; shift
	local stat=$1; shift

	ethtool -S $dev | grep "^ *$stat:" | head -n 1 | cut -d: -f2
}

declare -a VALS
collect()
{
	orig_time=$time
	time=$(date "+%s.%N") # Nanoseconds are reported with leading zeros
	local last_if
	local ethout

	for ((i=0; i< ${#COUNTERS[@]}; ++i)); do
                local orig=
                local val=
                eval ${COUNTERS[$i]}
		eval ${VALS[$i]}
		if [[ $if != $last_if ]]; then
			case "$counter" in
			IPL/*)
				ethout=$(ip -s -j l sh dev $if)
				;;
			ING/*)
				ethout=$(tc -j -s f sh dev $if ingress)
				;;
			EGR/*)
				ethout=$(tc -j -s f sh dev $if egress)
				;;
			ETH/*)
				ethout=$(ethtool -S $if)
				;;
			*/*)
				echo "Invalid counter family in $counter" >/dev/stderr
				exit 1
				;;
			*)
				ethout=$(ethtool -S $if)
				;;
			esac
		fi

                if [[ $update == tick ]]; then
                    orig=$((val))
                fi

		case "$counter" in
			IPL/*)
				val=$(($(echo "$ethout" | \
					jq ".[].stats64.${counter#IPL/}")))
				;;
			ING/* | EGR/*)
				val=$(($(echo "$ethout" | \
					 jq ".[1].options.${counter#*/}")))
				;;
			*)
				val=$(($(echo "$ethout" | grep "^ *$counter" \
					| head -n 1 | cut -d: -f2)))
				;;
		esac

                if [[ $update == once && $orig == "" ]]; then
                    orig=$((val))
                fi

                VALS[$i]="orig=$orig val=$val"
	done
}

collect
sleep 0.1
while true; do
	if ((N > 0)); then
		echo -ne "\033[${N}A"
	fi
	collect

	interval=$(echo "$time - $orig_time" | bc)
	echo -e "interval\t\033[K$interval"
	N=1

	for ((i=0; i< ${#COUNTERS[@]}; ++i)); do
	    eval ${COUNTERS[$i]}
	    eval ${VALS[$i]}

	    if [[ $type == Bb ]]; then
                val=$((8 * val))
                orig=$((8 * orig))
            fi

            if [[ $kind == relative ]]; then
                show=$(rate $orig $val $interval)
                unit=/s
            else
                show=$((val - orig))
                unit=
            fi

            case $type in
                Bb) unit="b$unit";;
                B)  unit="B$unit";;
                P)  unit="p$unit";;
                uS) unit="s$unit u m";;
            esac

            echo -e "$if $counter\t\033[K$(humanize $show $unit)"
	    N=$((N + 1))
	done

	sleep $sleep
done
