unit MDict;

interface

type
  MultiDict<TKey, TValue> = sealed partial class(ICollection<KeyValuePair<TKey,TValue>>)
    
    {$region Own interface}
    
    private comp: IEqualityComparer<TKey>;
    public constructor := Create(nil);
    public constructor(comp: IEqualityComparer<TKey>) := self.comp := comp ??
      System.Collections.Generic.EqualityComparer&<TKey>.Default;
    
    private _count := 0;
    public property Count: integer read _count;
    
    public procedure Add(key: TKey; value: TValue);
    public procedure Add(kv: KeyValuePair<TKey, TValue>) :=
      Add(kv.Key, kv.Value);
    public function ClearKey(key: TKey): integer;
    public procedure ClearAll;
    
    private function GetAllKV(key: TKey): sequence of KeyValuePair<TKey, TValue>;
    public property AllKV[key: TKey]: sequence of KeyValuePair<TKey, TValue> read GetAllKV;
    public property Keys[key: TKey]: sequence of TKey read GetAllKV(key).Select(kvp->kvp.Key);
    public property Values[key: TKey]: sequence of TValue read GetAllKV(key).Select(kvp->kvp.Value); default;
    
    private function GetUniqueKeys: sequence of TKey;
    public property UniqueKeys: sequence of TKey read GetUniqueKeys;
    
    public procedure EnsureCapacity(size: integer);
    
    {$endregion Own interface}
    
    {$region ICollection}
    
    ///--
    public procedure Clear := ClearAll;
    
    ///--
    public function Contains(kv: KeyValuePair<TKey,TValue>) :=
      kv.Value in Values[kv.Key];
    
    ///--
    public procedure CopyTo(a: array of KeyValuePair<TKey,TValue>; i: integer) :=
      foreach var kv in self do
      begin
        a[i] := kv;
        i += 1;
      end;
    
    ///--
    public function Remove(kv: KeyValuePair<TKey,TValue>): boolean;
    begin
      Result := false;
      raise new System.NotImplementedException;
    end;
    
    ///--
    public property IsReadOnly: boolean read boolean(false);
    
    private function EnumerateAll: sequence of KeyValuePair<TKey, TValue>;
    public function GetEnumerator := EnumerateAll.GetEnumerator;
    public function System.Collections.IEnumerable.GetEnumerator: System.Collections.IEnumerator := GetEnumerator;
    
    {$endregion ICollection}
    
  end;
  
implementation

type
  TrackableArrItem<TData> = record
    
    /// Index shift (plus 1) of the prev tracked item
    /// (so the default of 0 means shift by 1 left)
    /// If items[3] is tracked and items[3].prev_shift=5,
    /// the prev tracked item is at 3+5-1=7 (and modulo items.Length)
    /// Valid: 0 .. items.Length (extra 0)
    prev_shift: integer;
    /// Index shift (minus 1) of the next tracked item
    /// (so the default of 0 means shift by 1 right)
    /// If items[3] is tracked and items[3].next_shift=5,
    /// the next tracked item is at 3+5-1=9 (and modulo items.Length)
    /// Valid: -1 .. items.Length-2
    next_shift: integer;
    
    data: TData;
  end;
  ArrTracker = record
    /// Index of the first tracked element
    /// -1 when nothing is tracked
    first_ind: integer;
    
    static function Empty: ArrTracker; begin Result.first_ind := -1 end;
    static function Filled: ArrTracker; begin Result.first_ind := 0 end;
    
    static procedure Bind<T>(a: array of TrackableArrItem<T>; ind1, ind2: integer);
    begin
      a[ind1].next_shift := (ind2-ind1+a.Length) mod a.Length - 1;
      a[ind2].prev_shift := (ind1-ind2+a.Length) mod a.Length + 1;
    end;
    
    static function PrevInd<T>(a: array of TrackableArrItem<T>; ind: integer) := (ind+a[ind].prev_shift-1+a.Length) mod a.Length;
    static function NextInd<T>(a: array of TrackableArrItem<T>; ind: integer) := (ind+a[ind].next_shift+1) mod a.Length;
    
    procedure Add<T>(a: array of TrackableArrItem<T>; ind: integer);
    begin
      {$ifdef DEBUG}
      if a[ind].prev_shift<>0 then raise new System.InvalidOperationException;
      if a[ind].next_shift<>0 then raise new System.InvalidOperationException;
      {$endif DEBUG}
      
      if first_ind=-1 then
      begin
        a[ind].prev_shift := +1;
        a[ind].next_shift := -1;
        first_ind := ind;
        exit;
      end;
      
      var prev_ind := PrevInd(a, first_ind);
      Bind(a, prev_ind, ind);
      Bind(a, ind, first_ind);
      
      if first_ind=-1 then
        first_ind := ind;
    end;
    
    procedure Remove<T>(a: array of TrackableArrItem<T>; ind: integer);
    begin
      var prev_ind := PrevInd(a, ind);
      if prev_ind=ind then
        first_ind := -1 else
      begin
        var next_ind := NextInd(a, ind);
        Bind(a, prev_ind, next_ind);
        if first_ind=ind then
          first_ind := next_ind;
      end;
      {$ifdef DEBUG}
      a[ind].prev_shift := 0;
      a[ind].next_shift := 0;
      {$endif DEBUG}
    end;
    
    function TakeOutFirst<T>(a: array of TrackableArrItem<T>): integer;
    begin
      Result := self.first_ind;
      if Result=-1 then exit;
      Remove(a, Result);
    end;
    
    function Enumerate<T>(a: array of TrackableArrItem<T>): sequence of T;
    begin
      var ind := first_ind;
      if ind=-1 then exit;
      repeat
        yield a[ind].data;
        ind := NextInd(a, ind);
      until ind = first_ind;
    end;
    
  end;
  
  MultiDictEntry<TKey, TValue> = record
    key: TKey;
    value: TValue;
    /// -1 if this is the last entry in the chain
    chain_next_ind: integer;
  end;
  
  MultiDictIndexEntry = record
    /// Index in entries array (plus 1)
    /// (so the default of 0 means no entry)
    head_ind: integer;
    /// Plain index of last entry in the chain
    tail_ind: integer;
  end;
  
  MultiDict<TKey, TValue> = sealed partial class
    /// Incremented on every modification
    /// Used from VerifyVersion when enumerating contents
    private version := 0;
    
    /// Indexed by:
    /// 1. entry_index[hash].head_ind
    /// 2. entry_index[hash].tail_ind
    /// 3. entries[...].chain_next_ind
    private entries := new TrackableArrItem<MultiDictEntry<TKey, TValue>>[0];
    private used_entries := ArrTracker.Empty;
    private empty_entries := ArrTracker.Filled;
    
    /// Indexed by hash
    private entry_index := new TrackableArrItem<MultiDictIndexEntry>[0];
    private used_hashes := ArrTracker.Empty;
    
    private rehash_min_count := 0; // ReHash from ClearKey
    private const min_fill = 0.2;
    
    private static function Exchange<T>(var a: T; b: T): T;
    begin
      Result := a;
      a := b;
    end;
    private static small_prime_sizes := | // Stolen from https://referencesource.microsoft.com/#mscorlib/system/collections/hashtable.cs,1674
      3, 7, 11, 17, 23, 29, 37, 47, 59, 71, 89, 107, 131, 163, 197, 239, 293, 353, 431, 521, 631, 761, 919,
      1103, 1327, 1597, 1931, 2333, 2801, 3371, 4049, 4861, 5839, 7013, 8419, 10103, 12143, 14591,
      17519, 21023, 25229, 30293, 36353, 43627, 52361, 62851, 75431, 90523, 108631, 130363, 156437,
      187751, 225307, 270371, 324449, 389357, 467237, 560689, 672827, 807403, 968897, 1162687, 1395263,
      1674319, 2009191, 2411033, 2893249, 3471899, 4166287, 4999559, 5999471, 7199369
    |;
    private procedure ReHash(n_size: integer);
    begin
      {$ifdef DEBUG}
      if n_size<_count then
        raise new System.InvalidOperationException;
      {$endif DEBUG}
      
      if n_size<small_prime_sizes[0] then
        n_size := small_prime_sizes[0] else
      if n_size<=small_prime_sizes[^1] then
      begin
        var i := 0;
        var l := small_prime_sizes.Length;
        while l<>0 do
        begin
          var m := l shr 1;
          if small_prime_sizes[i+m]<n_size then
            i += m+1 else
            l -= l and 1;
          l -= m;
        end;
        n_size := small_prime_sizes[i];
      end else
      for var i := n_size or 1 to integer.MaxValue step 2 do
      begin
        if (3 .. i.Sqrt.Trunc).Step(2).Any(d->i.Divs(d)) then continue;
        n_size := i;
        break;
      end;
      
      var entries := Exchange(self.entries, new TrackableArrItem<MultiDictEntry<TKey, TValue>>[n_size]);
      var used_entries := Exchange(self.used_entries, ArrTracker.Empty);
      self.empty_entries := ArrTracker.Filled;
      
      self.entry_index := new TrackableArrItem<MultiDictIndexEntry>[n_size];
      self.used_hashes := ArrTracker.Empty;
      
      self.rehash_min_count := Trunc(n_size*min_fill);
      
      self._count := 0;
      
      foreach var e in used_entries.Enumerate(entries) do
        self.Add(e.key, e.value);
    end;
    
    private function Hash(key: TKey): cardinal := cardinal(comp.GetHashCode(key)) mod entries.Length;
    private procedure VerifyVersion(org_version: integer);
    begin
      if self.version=org_version then exit;
      raise new System.InvalidOperationException('Collection modified');
    end;
    
    private procedure AddImpl(key: TKey; value: TValue);
    begin
      version += 1;
      if self._count = entries.Length then
        ReHash(entries.Length*2);
      self._count += 1;
      var hash := self.Hash(key);
      
      var new_entry_ind := empty_entries.TakeOutFirst(entries);
      {$ifdef DEBUG}
      if new_entry_ind=-1 then
        raise new System.InvalidOperationException;
      {$endif DEBUG}
      used_entries.Add(entries, new_entry_ind);
      
      if entry_index[hash].data.head_ind=0 then
      begin
        entry_index[hash].data.head_ind := new_entry_ind+1;
        used_hashes.Add(entry_index, hash);
      end else
        entries[entry_index[hash].data.tail_ind].data.chain_next_ind := new_entry_ind;
      entry_index[hash].data.tail_ind := new_entry_ind;
      
      var entry_data: MultiDictEntry<TKey, TValue>;
      entry_data.chain_next_ind := -1;
      entry_data.key := key;
      entry_data.value := value;
      entries[new_entry_ind].data := entry_data;
    end;
    
    private function ClearKeyImpl(key: TKey): integer;
    begin
      Result := 0;
      version += 1;
      var hash := self.Hash(key);
      var any_kept := true;
      
      var entry_ind := entry_index[hash].data.head_ind-1;
      while entry_ind<>-1 do
      begin
        var curr_entry_ind := entry_ind;
        entry_ind := entries[entry_ind].data.chain_next_ind;
        if comp.Equals(entries[curr_entry_ind].data.key, key) then
        begin
          Result += 1;
          // Write zeroes in case TKey or TValue contain references
          // Otherwise such references can prevent garbage collection
          entries[curr_entry_ind].data := default(MultiDictEntry<TKey, TValue>);
          //TODO Inefficient, to remove/add one index at a time
          // - But need ref-variables to make this not just fast but readable
          used_entries.Remove(entries, curr_entry_ind);
          empty_entries.Add(entries, curr_entry_ind);
        end else
        if not any_kept then
        begin
          entry_index[hash].data.head_ind := curr_entry_ind+1;
          any_kept := true;
        end;
      end;
      _count -= Result;
      
      if not any_kept then
      begin
        entry_index[hash].data.head_ind := 0;
        used_hashes.Remove(entry_index, hash);
      end;
      
      if _count<rehash_min_count then
        ReHash(_count);
    end;
    
    private function GetAllKVImpl(key: TKey): sequence of KeyValuePair<TKey, TValue>;
    begin
      var org_version := self.version;
      var hash := self.Hash(key);
      
      var entry_ind := entry_index[hash].data.head_ind-1;
      while entry_ind<>-1 do
      begin
        var e := entries[entry_ind].data;
        if comp.Equals(e.key, key) then
        begin
          yield KV(e.key, e.value);
          VerifyVersion(org_version);
        end;
        entry_ind := entries[entry_ind].data.chain_next_ind;
      end;
      
    end;
    
    private function GetUniqueKeysImpl: sequence of TKey;
    begin
      var org_version := self.version;
      var old_keys := new List<TKey>;
      foreach var ie in used_hashes.Enumerate(entry_index) do
      begin
        var entry_ind := ie.head_ind-1;
        {$ifdef DEBUG}
        if entry_ind=-1 then
          raise new System.InvalidOperationException;
        {$endif DEBUG}
        repeat
          var key := entries[entry_ind].data.key;
          var is_unique := true;
          foreach var old_key in old_keys do
          begin
            if not comp.Equals(old_key, key) then continue;
            is_unique := false;
            break;
          end;
          if is_unique then
          begin
            yield key;
            VerifyVersion(org_version);
            old_keys.Add(key);
          end;
          entry_ind := entries[entry_ind].data.chain_next_ind;
        until entry_ind=-1;
        old_keys.Clear;
      end;
    end;
    
    private procedure EnsureCapacityImpl(size: integer);
    begin
      version += 1;
      if entries.Length >= size then exit;
      ReHash(size);
    end;
    
    private procedure ClearAllImpl;
    begin
      self.version += 1;
      self.entries := new TrackableArrItem<MultiDictEntry<TKey, TValue>>[0];
      self.used_entries := ArrTracker.Empty;
      self.empty_entries := ArrTracker.Filled;
      self.entry_index := new TrackableArrItem<MultiDictIndexEntry>[0];
      self.used_hashes := ArrTracker.Empty;
      self.rehash_min_count := 0;
    end;
    
    private function EnumerateAllImpl: sequence of KeyValuePair<TKey, TValue>;
    begin
      var org_version := self.version;
      foreach var e in used_entries.Enumerate(entries) do
      begin
        yield KV(e.key, e.value);
        VerifyVersion(org_version);
      end;
    end;
    
  end;
  
procedure MultiDict<TKey,TValue>.Add(key: TKey; value: TValue) := AddImpl(key, value);

function MultiDict<TKey,TValue>.ClearKey(key: TKey) := ClearKeyImpl(key);

function MultiDict<TKey,TValue>.GetAllKV(key: TKey) := GetAllKVImpl(key);

function MultiDict<TKey,TValue>.GetUniqueKeys := GetUniqueKeysImpl;

procedure MultiDict<TKey,TValue>.EnsureCapacity(size: integer) := EnsureCapacityImpl(size);

procedure MultiDict<TKey,TValue>.ClearAll := ClearAllImpl;

function MultiDict<TKey,TValue>.EnumerateAll := EnumerateAllImpl;

end.