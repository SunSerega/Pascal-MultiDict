## uses MDict;

var d := new MultiDict<byte, integer>;

var n := 100;
for var i := 1 to n do
begin
  d.Add(1, i);
  loop 1000 do
    d.Add(2, 0);
end;

d[2].Distinct.Count.Println;
d[2].Count.Println;

d[1].Distinct.Count.Println;
d[1].Count.Println;

d[1].SequenceEqual(1..n).Println;
//d[1].Println;

d.ClearKey(2);
Println('='*30);

d[2].Distinct.Count.Println;
d[2].Count.Println;

d[1].Distinct.Count.Println;
d[1].Count.Println;

d[1].SequenceEqual(1..n).Println;
//d[1].Println;

;