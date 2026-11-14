# Запускать только в отдельной тестовой БД: сценарии очищают её данные.
import os, subprocess, select, time
if not os.environ.get('PGDATABASE'):
 raise SystemExit('Set PGDATABASE to an isolated test database')
BASE = 'set role inspector; set search_path to kalugin_food,exts; '
def query(sql):
 r=subprocess.run(['psql','-XqAt','-v','ON_ERROR_STOP=1','-c',(sql if 'pg_stat_activity' in sql else BASE+sql)],capture_output=True,text=True,timeout=20)
 if r.returncode: raise RuntimeError(r.stderr)
 return r.stdout.strip()
def session(name, isolation):
 p=subprocess.Popen(['psql','-XqAt','-v','ON_ERROR_STOP=1'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,bufsize=1)
 p.stdin.write("\\set VERBOSITY verbose\n"+BASE+f"set application_name='{name}'; begin isolation level {isolation}; do $$ begin perform count(*) from product; end; $$; select 'ready';\n");p.stdin.flush()
 while True:
  if not select.select([p.stdout],[],[],10)[0]: raise RuntimeError('Session setup timeout')
  line=p.stdout.readline().strip()
  if line=='ready': return p
  if not line and p.poll() is not None: raise RuntimeError(p.stderr.read())
def send(p,sql):p.stdin.write(sql+'\n');p.stdin.flush()
def marker(p):
 while True:
  line=p.stdout.readline().strip()
  if line=='written':return
  if not line and p.poll() is not None: raise RuntimeError(p.stderr.read())
def run_case(label, isolation, first, second, expected):
 a=session('foodexpress_a',isolation);b=session('foodexpress_b',isolation)
 try:
  send(a,first+"; select 'written';");marker(a)
  send(b,second+'; commit;');b.stdin.close()
  blocked=False
  for _ in range(80):
   wait=query("select wait_event_type from pg_stat_activity where application_name='foodexpress_b' and state='active'")
   if 'Lock' in wait:blocked=True;break
   if b.poll() is not None:break
   time.sleep(.025)
  if not blocked: raise RuntimeError(label+' did not wait for concurrent writer')
  send(a,'commit;');a.stdin.close();a.wait(timeout=10)
  b.wait(timeout=10);err=b.stderr.read()
  if a.returncode:raise RuntimeError(a.stderr.read())
  if expected=='ok' and b.returncode:raise RuntimeError(err)
  if expected!='ok' and (not b.returncode or expected not in err):raise RuntimeError(label+' unexpected outcome '+err)
  print(label,isolation,expected,flush=True)
 finally:
  for p in [a,b]:
   if p.poll() is None:p.kill();p.wait()

query('call erase_test_data(); call insert_test_data(200);')
ids=query("select string_agg(review_id::text,',') from (select review_id from review where entity_type='блюдо' and entity_id=(select entity_id from review where entity_type='блюдо' group by entity_id having count(*)>=2 limit 1) limit 2) x").split(',')
assert len(ids)==2
for isolation in ['read committed','repeatable read']:
 run_case('rating',isolation,f"update review set rating=case when rating=1 then 5 else 1 end where review_id='{ids[0]}'",f"update review set rating=case when rating=1 then 5 else 1 end where review_id='{ids[1]}'",'ok' if isolation=='read committed' else '40001')
 assert query("select count(*) from product p where rating is distinct from (select round(avg(r.rating),2) from review r where r.entity_type='блюдо' and r.entity_id=p.product_id)")=='0'

for isolation in ['read committed','repeatable read']:
 order_key,payment_key=query("select o.order_id,p.payment_id from \"order\" o join payment p using(order_id) where p.status='успех' limit 1").split('|')
 query(f"update \"order\" set status='создан' where order_id='{order_key}'")
 run_case('payment',isolation,f"update \"order\" set status='доставлен' where order_id='{order_key}'",f"update payment set status='ошибка' where payment_id='{payment_key}'",'23514' if isolation=='read committed' else '40001')
 assert query('select count(*) from "order" o where status=\'доставлен\' and not exists(select from payment p where p.order_id=o.order_id and p.status=\'успех\')')=='0'

for isolation in ['read committed','repeatable read']:
 order_key, restaurant_key, foreign_restaurant=query('select o.order_id,o.restaurant_id,r.restaurant_id from "order" o join restaurant r on r.restaurant_id<>o.restaurant_id limit 1').split('|')
 category=query('select product_category_id from product_category limit 1')
 query(f"call add_product('{restaurant_key}','{category}','Concurrency product',100,'Test');")
 product_key=query("select product_id from product where product_name='Concurrency product' order by product_id limit 1")
 run_case('restaurant',isolation,f"insert into order_structure values ('{order_key}','{product_key}',1)",f"update product set restaurant_id='{foreign_restaurant}' where product_id='{product_key}'",'23514' if isolation=='read committed' else '40001')
 assert query('select count(*) from order_structure s join "order" o using(order_id) join product p using(product_id) where o.restaurant_id<>p.restaurant_id')=='0'
 query(f"delete from order_structure where product_id='{product_key}'; delete from product where product_id='{product_key}';")
print('All concurrent scenarios passed',flush=True)
