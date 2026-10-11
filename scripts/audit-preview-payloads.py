"""Read-only bounded hash audit of exact public preview-root payloads; no acceptance verdict."""
import argparse,pathlib,json,os,stat,re,hashlib,time
parser=argparse.ArgumentParser();parser.add_argument('--native-root',required=True,type=pathlib.Path);parser.add_argument('--output',required=True,type=pathlib.Path);args=parser.parse_args()
with args.native_root.open('rb') as supplied:
 data=supplied.read(1048577)
assert len(data)<=1048576,'Native root record exceeds bounded input'
v=json.loads(data);assert type(v) is dict and v['encoding']=='UnixBytes' and type(v['units']) is list
assert v['units'] and v['units'][0]==47 and all(type(x) is int and 0<=x<=255 for x in v['units']) and 0 not in v['units'] and len(v['units'])<=32768
root=os.fsdecode(bytes(v['units']));parts=root.split('/')[1:];assert all(x not in ('','.', '..') for x in parts)
report_path=args.output.resolve();assert os.path.commonpath([root,str(report_path)])!=root,'Audit report must remain outside the cache root'
rootfd=os.open('/',os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
try:
 for name in parts:
  nxt=os.open(name,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=rootfd);os.close(rootfd);rootfd=nxt
 def identity(s):return(s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns,s.st_ctime_ns,s.st_nlink,s.st_mode)
 def fail(error):raise error
 records=[];size=0
 visited=0;deadline=time.monotonic()+60
 def bounded_entries(directoryfd,parent='.',depth=0):
  global visited
  assert depth<=8,'Cache directory depth exceeds audit bound'
  with os.scandir(directoryfd) as entries:
   for entry in entries:
    visited+=1;assert visited<=50000 and time.monotonic()<deadline,'Cache traversal exceeds finite audit bound'
    metadata=entry.stat(follow_symlinks=False)
    assert not stat.S_ISLNK(metadata.st_mode),'Linked cache entry'
    if stat.S_ISDIR(metadata.st_mode):
     assert not re.fullmatch('[0-9a-f]{64}',entry.name),'Invalid cache directory'
     child=os.open(entry.name,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=directoryfd)
     try:
      assert identity(os.fstat(child))==identity(metadata),'Cache directory replaced before audit'
      yield from bounded_entries(child,os.path.join(parent,entry.name),depth+1)
     finally:os.close(child)
    else:yield parent,directoryfd,entry.name
 for parent,parentfd,name in bounded_entries(rootfd):
  s=os.stat(name,dir_fd=parentfd,follow_symlinks=False);assert not stat.S_ISLNK(s.st_mode),'Linked cache file'
  if not re.fullmatch('[0-9a-f]{64}',name):continue
  assert stat.S_ISREG(s.st_mode),'Nonregular payload'
  assert len(records)<10000 and s.st_size<=32*1024*1024 and size+s.st_size<=512*1024*1024,'Fixture payload audit bound exceeded'
  fd=os.open(name,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK,dir_fd=parentfd);h=hashlib.sha256();read=0
  with os.fdopen(fd,'rb') as f:
   before=os.fstat(f.fileno());assert stat.S_ISREG(before.st_mode) and identity(before)==identity(s),'Payload replaced or changed before audit'
   while block:=f.read(min(65536,s.st_size-read+1)):
    read+=len(block);assert time.monotonic()<deadline,'Payload read exceeds audit time bound';assert read<=s.st_size and read<=32*1024*1024 and size+read<=512*1024*1024,'Actual payload read exceeded finite audit bounds';h.update(block)
   after=os.fstat(f.fileno());assert read==s.st_size and identity(before)==identity(after),'Payload changed during audit'
  records.append({'relative_path':os.path.normpath(os.path.join(parent,name)),'object_key':name,'bytes':read,'sha256':h.hexdigest()});size+=read
 assert len({x['object_key'] for x in records})==len(records),'Duplicate payload key'
 args.output.write_text(json.dumps({'scope':'Read-only actual public-root payload filesystem audit; no app/relocation acceptance','native_root':v,'canonical_root':root,'recorded_epoch':time.time(),'objects':len(records),'bytes':size,'records':sorted(records,key=lambda x:x['relative_path'])},indent=2)+'\n')
 print(json.dumps({'objects':len(records),'bytes':size,'status':'RECORDED_ONLY'}))
finally:os.close(rootfd)
