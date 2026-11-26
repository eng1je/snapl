-- Run once in Supabase SQL Editor. All game state is private.
create schema if not exists sanabel_private;
create table if not exists sanabel_private.rooms(code text primary key, members uuid[] not null, names text[] not null, n int not null check(n in (2,4)), target int not null, state jsonb, rev bigint not null default 0, sticker jsonb, updated timestamptz default now());
revoke all on schema sanabel_private from public, anon, authenticated;
create or replace function sanabel_private.new_round(n int, target int, totals jsonb, r int) returns jsonb language plpgsql set search_path='' as $$
declare d int[]; h jsonb; begin
select array_agg(i order by random()) into d from generate_series(0,39) i;
select jsonb_agg(to_jsonb(d[5+i*3:7+i*3]) order by i) into h from generate_series(0,n-1) i;
return jsonb_build_object('n',n,'target',target,'totals',totals,'r',r,'deck',to_jsonb(d[5+n*3:40]),'table',to_jsonb(d[1:4]),'hands',h,'captured','[[],[]]'::jsonb,'sweeps','[0,0]'::jsonb,'turn',(r-1)%n,'last',-1,'phase','playing','gain','[0,0]'::jsonb,'event','');end $$;
create or replace function sanabel_private.arr(a jsonb) returns int[] language sql immutable set search_path='' as $$select coalesce(array_agg(value::int),array[]::int[]) from jsonb_array_elements_text(a)$$;
create or replace function sanabel_private.remove_cards(a jsonb,b int[]) returns jsonb language sql immutable set search_path='' as $$select coalesce(jsonb_agg(v order by ord),'[]'::jsonb) from jsonb_array_elements(a) with ordinality x(v,ord) where not ((v::text)::int=any(b))$$;
create or replace function public.sanabel(p_action text,p_code text default '',p_payload jsonb default '{}'::jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid(); nm text; rm sanabel_private.rooms%rowtype; c text; n int; target int; seat int; s jsonb; hand int[]; tab int[]; take int[]; deck int[]; card int; val int; team int; last int; i int; j int; a int; b int; p int[]; totals int[]; cap int[]; eq boolean; possible boolean; sums int[]; x int; z int; finalmove boolean; begin
if u is null then raise exception 'Login required'; end if;
nm:=left(coalesce(nullif(auth.jwt()->'user_metadata'->>'nickname',''),'لاعب'),24);
if p_action='create' then
 n:=(p_payload->>'n')::int; target:=(p_payload->>'target')::int;
 if n is null or n not in(2,4) or target is null or target not in(11,21,30,60) then raise exception 'Invalid settings';end if;
 loop c:=upper(substr(replace(gen_random_uuid()::text,'-',''),1,8)); begin insert into sanabel_private.rooms(code,members,names,n,target) values(c,array[u],array[nm],n,target);exit; exception when unique_violation then null; end;end loop;
else c:=upper(trim(p_code));end if;
select * into rm from sanabel_private.rooms where code=c for update;
if not found then raise exception 'Room not found';end if;
seat:=array_position(rm.members,u)-1;
if p_action='join' and seat is null then
 if rm.state is not null or cardinality(rm.members)>=rm.n then raise exception 'Room full or started';end if;
 rm.members:=array_append(rm.members,u);rm.names:=array_append(rm.names,nm);seat:=cardinality(rm.members)-1;rm.rev:=rm.rev+1;
end if;
if seat is null then raise exception 'Not a room member';end if;
s:=rm.state;
if p_action='start' then
 if seat<>0 or s is not null or cardinality(rm.members)<>rm.n then raise exception 'Cannot start';end if;
 s:=sanabel_private.new_round(rm.n,rm.target,'[0,0]'::jsonb,1);rm.rev:=rm.rev+1;
elsif p_action='next' then
 if s is null or s->>'phase'<>'round_end' then raise exception 'Round not over';end if;
 s:=sanabel_private.new_round(rm.n,rm.target,s->'totals',(s->>'r')::int+1);rm.rev:=rm.rev+1;
elsif p_action='sticker' then
 if rm.sticker is not null and (rm.sticker->>'seat')::int=seat and (rm.sticker->>'at')::timestamptz>now()-interval '2 seconds' then raise exception 'Slow down';end if;
 if (p_payload->>'text') is null or (p_payload->>'text') not in ('😂','🔥','👏','👑','😱','❤️','هكي اللعب','شكبة يا معلم','تي العب','حظك قوي','مبروك عليك','تو تشوف') then raise exception 'Invalid sticker';end if;
 rm.sticker:=jsonb_build_object('seat',seat,'text',p_payload->>'text','at',now());rm.rev:=rm.rev+1;
elsif p_action='move' then
 if s is null or s->>'phase'<>'playing' or (s->>'turn')::int<>seat or (p_payload->>'rev')::bigint is distinct from rm.rev then raise exception 'Not your turn or outdated move';end if;
 card:=(p_payload->>'card')::int;take:=sanabel_private.arr(coalesce(p_payload->'take','[]'::jsonb));hand:=sanabel_private.arr(s->'hands'->seat);tab:=sanabel_private.arr(s->'table');val:=card%10+1;team:=seat%2;
 if card is null or not(card=any(hand)) or not(take<@tab) or cardinality(take)<>(select count(distinct v) from unnest(take) v) then raise exception 'Invalid cards';end if;
 select exists(select 1 from unnest(tab) v where v%10+1=val) into eq;
 sums:=array[0];foreach x in array tab loop select array_agg(distinct q) into sums from (select unnest(sums) q union select v+x%10+1 from unnest(sums) v where v+x%10+1<=val) t;end loop;
 possible:=val=any(sums);
 if cardinality(take)=0 then if possible then raise exception 'Capture required';end if;
 elsif (select sum(v%10+1) from unnest(take) v)<>val or (eq and cardinality(take)<>1) then raise exception 'Invalid capture';end if;
 s:=jsonb_set(s,array['hands',seat::text],sanabel_private.remove_cards(s->'hands'->seat,array[card]));
 select coalesce(sum(jsonb_array_length(v)),0)=0 into finalmove from jsonb_array_elements(s->'hands') v;
 s:=jsonb_set(s,'{event}','""'::jsonb);
 if cardinality(take)>0 then
 s:=jsonb_set(s,array['captured',team::text],(s->'captured'->team)||to_jsonb(array_append(take,card)));
 s:=jsonb_set(s,'{table}',sanabel_private.remove_cards(s->'table',take));s:=jsonb_set(s,'{last}',to_jsonb(team));
 if jsonb_array_length(s->'table')=0 and not(finalmove and jsonb_array_length(s->'deck')=0) then s:=jsonb_set(s,array['sweeps',team::text],to_jsonb((s->'sweeps'->>team)::int+1));s:=jsonb_set(s,'{event}',to_jsonb('شكبة!'::text));end if;
 else s:=jsonb_set(s,'{table}',(s->'table')||to_jsonb(array[card]));end if;
 if finalmove then
 deck:=sanabel_private.arr(s->'deck');
 if cardinality(deck)>0 then for i in 0..rm.n-1 loop s:=jsonb_set(s,array['hands',i::text],to_jsonb(deck[1+i*3:3+i*3]));end loop;s:=jsonb_set(s,'{deck}',to_jsonb(deck[1+rm.n*3:cardinality(deck)]));
 else
 last:=(s->>'last')::int;if last>=0 then s:=jsonb_set(s,array['captured',last::text],(s->'captured'->last)||(s->'table'));end if;s:=jsonb_set(s,'{table}','[]'::jsonb);
 p:=sanabel_private.arr(s->'sweeps');
 for i in 0..2 loop
 select count(*) into a from unnest(sanabel_private.arr(s->'captured'->0)) v where i=0 or (i=1 and v/10=0) or (i=2 and v%10=6);
 select count(*) into b from unnest(sanabel_private.arr(s->'captured'->1)) v where i=0 or (i=1 and v/10=0) or (i=2 and v%10=6);
 if a>b then p[1]:=p[1]+1;elsif b>a then p[2]:=p[2]+1;end if;end loop;
 if 6=any(sanabel_private.arr(s->'captured'->0)) then p[1]:=p[1]+1;elsif 6=any(sanabel_private.arr(s->'captured'->1)) then p[2]:=p[2]+1;end if;
 totals:=sanabel_private.arr(s->'totals');totals[1]:=totals[1]+p[1];totals[2]:=totals[2]+p[2];s:=jsonb_set(s,'{gain}',to_jsonb(p));s:=jsonb_set(s,'{totals}',to_jsonb(totals));s:=jsonb_set(s,'{phase}',to_jsonb(case when greatest(totals[1],totals[2])>=rm.target and totals[1]<>totals[2] then 'finished' else 'round_end' end));
 end if;end if;
 s:=jsonb_set(s,'{turn}',to_jsonb((seat+1)%rm.n));rm.rev:=rm.rev+1;
elsif p_action not in ('create','join','get') then raise exception 'Unknown action';end if;
if p_action<>'get' then update sanabel_private.rooms set members=rm.members,names=rm.names,state=s,rev=rm.rev,sticker=rm.sticker,updated=now() where code=c;end if;
return jsonb_build_object('code',c,'seat',seat,'names',rm.names,'n',rm.n,'target',rm.target,'rev',rm.rev,'sticker',rm.sticker,'state',case when s is null then null else (s-'hands'-'deck'-'captured')||jsonb_build_object('hand',s->'hands'->seat,'counts',(select jsonb_agg(jsonb_array_length(v)) from jsonb_array_elements(s->'hands') v),'remaining',jsonb_array_length(s->'deck')) end);
end $$;
revoke all on function public.sanabel(text,text,jsonb) from public, anon;
grant execute on function public.sanabel(text,text,jsonb) to authenticated;
