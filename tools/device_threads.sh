#!/system/bin/sh
# Run on the device (adb shell sh /data/local/tmp/flintkart_profile/device_threads.sh):
# for each thread of the running game, the CPU it last ran on and how many
# clock ticks it used over 5 s, plus each core's clock. #54's core check.
P=$(pidof com.flintkart.game)
[ -z "$P" ] && { echo "game not running"; exit 1; }
for t in /proc/$P/task/*; do
  echo "$(basename $t) $(cut -d' ' -f14,15 $t/stat | tr ' ' '+' )" ; done > /data/local/tmp/flintkart_profile/t0
sleep 5
for t in /proc/$P/task/*; do
  id=$(basename $t)
  now=$(( $(cut -d' ' -f14 $t/stat) + $(cut -d' ' -f15 $t/stat) ))
  was=$(grep "^$id " /data/local/tmp/flintkart_profile/t0 | cut -d' ' -f2)
  was=$(( ${was:-0} ))
  echo "$(( now - was )) ticks cpu$(cut -d' ' -f39 $t/stat) $(cat $t/comm)"
done | sort -n -r | head -10
echo "cur kHz: $(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq | tr '\n' ' ')"
echo "max kHz: $(cat /sys/devices/system/cpu/cpu*/cpufreq/cpuinfo_max_freq | tr '\n' ' ')"
