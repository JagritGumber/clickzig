#!/bin/sh
# Reference timings with clickhouse-client (C++), run inside the ClickHouse
# container. Prints JSON lines for bench/collect.py --reference.
CH="clickhouse-client --password test"
median() { sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}'; }
run() { # name compression rows query
  name=$1; comp=$2; rows=$3; q=$4
  $CH --compression $comp -q "$q FORMAT Native" >/dev/null 2>&1
  t=$(for i in 1 2 3 4 5 6 7; do $CH --compression $comp --time -q "$q FORMAT Native" 2>&1 >/dev/null | tail -1; done | median)
  echo "{\"bench\":\"$name\",\"client\":\"clickhouse-client\",\"rows\":$rows,\"s\":$t}"
}
run read_uint64 0 20000000 "SELECT number FROM numbers(20000000)"
run read_uint64_lz4 1 20000000 "SELECT number FROM numbers(20000000)"
run read_string 0 5000000 "SELECT toString(number) AS s FROM numbers(5000000)"
run read_string_lz4 1 5000000 "SELECT toString(number) AS s FROM numbers(5000000)"
$CH -q "CREATE TABLE IF NOT EXISTS bench_insert (id UInt64, label String, value Float64) ENGINE = Null"
$CH -q "SELECT number AS id, concat('event-', toString(number % 5000), '-', if(number % 3 = 0, 'click', 'view')) AS label, number*0.25 AS value FROM numbers(100000) FORMAT Native" > /tmp/x.native
t=$(for i in 1 2 3 4 5 6 7; do $CH --compression 0 --time -q "INSERT INTO bench_insert FORMAT Native" < /tmp/x.native 2>&1 | tail -1; done | median)
echo "{\"bench\":\"insert_none\",\"client\":\"clickhouse-client\",\"rows\":100000,\"s\":$t}"
$CH -q "DROP TABLE bench_insert"
