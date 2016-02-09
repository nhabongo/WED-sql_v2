--CREATE LANGUAGE plpython3u;
--CREATE ROLE wed_admin WITH superuser noinherit;
--GRANT wed_admin TO wedflow;

--SET ROLE wed_admin;
--Insert (or modify) a new WED-atribute in the apropriate tables 
------------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION wed_attr_handler_aft() RETURNS TRIGGER AS 
$wah$
    #--plpy.info('Trigger "'+TD['name']+'" ('+TD['event']+','+TD['when']+') on "'+TD['table_name']+'"')
    if TD['event'] == 'INSERT':
        #--plpy.notice('Inserting new attribute: ' + TD['new']['name'])
        try:
            plpy.execute('ALTER TABLE wed_flow ADD COLUMN ' 
                         + plpy.quote_ident(TD['new']['aname']) 
                         + ' TEXT DEFAULT ' 
                         + (plpy.quote_literal(TD['new']['adv']) if TD['new']['adv'] else 'NULL'))
        except plpy.SPIError:
            plpy.error('Could not insert new column at wed_flow')
        else:
            plpy.info('Column "'+TD['new']['aname']+'" inserted into wed_flow')
            
    elif TD['event'] == 'UPDATE':
        if TD['new']['aname'] != TD['old']['aname']:
            #--plpy.notice('Updating attribute name: ' + TD['old']['name'] + ' -> ' + TD['new']['name'])
            try:
                plpy.execute('ALTER TABLE wed_flow RENAME COLUMN ' 
                             + plpy.quote_ident(TD['old']['aname']) 
                             + ' TO ' 
                             + plpy.quote_ident(TD['new']['aname']))
            except plpy.SPIError:
                plpy.error('Could not rename columns at wed_flow')
            else:
                plpy.info('Column name updated in wed_flow')
            
        if TD['new']['adv'] != TD['old']['adv']:
            #--plpy.notice('Updating attribute '+TD['old']['name']+' default value :' 
            #--            + TD['old']['default_value'] + ' -> ' + TD['new']['default_value'])
            try:
                plpy.execute('ALTER TABLE wed_flow ALTER COLUMN ' 
                             + plpy.quote_ident(TD['new']['aname']) 
                             + ' SET DEFAULT ' 
                             + (plpy.quote_literal(TD['new']['adv']) if TD['new']['adv'] else 'NULL'))
            except plpy.SPIError:
                plpy.error('Could not modify columns at wed_flow')
            else:
                plpy.info('Column default value updated in wed_flow')
    else:
        plpy.error('UNDEFINED EVENT')
        return None
    return None    
$wah$ LANGUAGE plpython3u SECURITY DEFINER;

DROP TRIGGER IF EXISTS wed_attr_trg_aft ON wed_attr;
CREATE TRIGGER wed_attr_trg_aft
AFTER INSERT OR UPDATE ON wed_attr
    FOR EACH ROW EXECUTE PROCEDURE wed_attr_handler_aft();

--Insert a WED-flow modification into WED-trace (history)
------------------------------------------------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION kernel_function() RETURNS TRIGGER AS $kt$
    
    from os import urandom
    from datetime import datetime
    import hashlib
    import json
    
    plpy.info(TD['args'])
    
    #--Generates new instance trigger token ----------------------------------------------------------------------------
    def new_uptkn(trigger_name):
        salt = urandom(5)
        hash = hashlib.md5(salt + trigger_name)
        return hash.hexdigest()

    #--Match predicates against the new state -------------------------------------------------------------------------
    def pred_match(wid):
        
        trmatched = []
        try:
            res_wed_trig = plpy.execute('select * from wed_trig')
        except plpy.SPIError:
            plpy.error('wed_trig scan error')
        else:
            for tr in res_wed_trig:
                try:
                    res_wed_flow = plpy.execute('select * from wed_flow where wid='+str(wid)+' and ('+tr['cpred']+')')
                except plpy.SPIError:
                    plpy.error('wed_flow scan error')
                else:
                    if res_wed_flow:
                        plpy.notice(tr['trname'],tr['cpred'])
                        trmatched.append((tr['trname'],tr['timeout']))
        
        return trmatched
   
    def json_wed_state():
        payload = TD['new'].copy()
        del payload['wid']
        
        return json.dumps(payload)
        
    
    #--Fire WED-triggers given a WED-condtions set  --------------------------------------------------------------------
    def squeeze_all_triggers(trmatched):
        
        trfired = []
        
        if ('_FINAL',None) in trmatched:
            return trfired
        
        wid = TD['new']['wid']
        payload = json_wed_state()
        
        plan = plpy.prepare('insert into job_pool (wid,trname,timeout,payload) values ($1,$2,$3,$4)',['integer','text','interval','json'])
        
        for trname,timeout in trmatched:
            try:
                plpy.execute(plan,[wid,trname,timeout,payload])
            except plpy.SPIError as e:
                plpy.info('INSERT ERROR: JOB_POOL', e)
                #--pass
            else:
                trfired.append(trname)
                try:
                    plpy.execute('NOTIFY '+trname+', \''+json.dumps(TD['new'])+'\'')
                except plpy.SPIError as e:
                    plpy.notice('Notification error:',e)
                    
        return trfired
                
    #--Create a new entry on history (WED_trace table) -----------------------------------------------------------------
    def new_trace_entry(trw=None,trf=None,final=False,excpt=False):
     
        payload = json_wed_state()
        
        plan = plpy.prepare('INSERT INTO wed_trace (wid,trw,trf,final,excpt,state) VALUES ($1,$2,$3,$4,$5,$6)',['integer','text','text[]','bool','bool','json'])
        try:
            plpy.execute(plan, [TD['new']['wid'],trw,trf,final,excpt,payload])
        except plpy.SPIError as e:
            plpy.info('Could not insert new entry into wed_trace')
            plpy.error(e)
    
    #-- Create a new entry on ST_STATUS for fast detecting final states ------------------------------------------------
    def new_st_status_entry():
        try:
            plpy.execute('INSERT INTO st_status (wid) VALUES (' + str(TD['new']['wid']) + ')')
        except plpy.SPIError as e:
            plpy.info('Could not insert new entry into st_status')
            plpy.error(e)    
    
    
    #-- Find job with uptkn on JOB_POOL (locked and inside timout window)-----------------------------------------------
    def find_job(uptkn):
    
        tf_str = plpy.quote_literal(str(datetime.now()))
        
        query = 'update job_pool set tf='+tf_str+'::timestamp where uptkn='+plpy.quote_literal(uptkn)+\
                ' and locked and tf is null'+\
                ' returning tgid,wid,uptkn,locked,tout,ti,tf'
        #--plpy.info(query)
        
        try:
            with plpy.subtransaction():
                plpy.execute('alter table job_pool disable trigger lock_job')
                res = plpy.execute(query)
                plpy.execute('alter table job_pool enable trigger lock_job')
        except plpy.SPIError:
            plpy.error('Find job error')
        else:
            return res[0] if res else None
            
    #-- scan job_pool for pending transitions for WED-flow instance wid
    def running_triggers(wid):
        try:
            res = plpy.execute('select tgid from job_pool where wid='+str(wid)+' and tf is null')
        except plpy.SPIError:
            plpy.error('ERROR: job_pool scanning')
        else:
            return {x['tgid'] for x in res}
    
    #-- Check if a given wed-flow instance is already on a final state -------------------------------------------------
    def get_st_status(wid):
        try:
            res = plpy.execute('select final,excpt from st_status where wid='+str(wid))
        except plpy.SPIError:
            plpy.error('Reading st_status')
        else:
            if not len(res):
                plpy.error('wid not found !')
            else:
                return (res[0]['final'],res[0]['excpt'])
    
    #-- Set an WED-state status (final or not final)
    def set_st_status(final=True,excpt=False):
        try:
            res = plpy.execute('update st_status set final='+str(final)+',excpt='+str(excpt)+' where wid='+str(TD['new']['wid']))
        except plpy.SPIError:
            plpy.error('Status set error on st_status table')

    #--(START) TRIGGER CODE --------------------------------------------------------------------------------------------
            
    #--Only get the WED-attributes columns to insert into WED-trace-----------------------------------------------------
    k,v = zip(*TD['new'].items())
    
    plpy.info(k,v)
    #--plpy.error('NHAGA')
    
    #-- New wed-flow instance (AFTER INSERT)----------------------------------------------------------------------------
    if TD['event'] in ['INSERT']:
        
        trmatched = pred_match(TD['new']['wid'])
        final = ('_FINAL',None) in trmatched
        
        if (not trmatched):
            plpy.error('No predicate matches this initial WED-state, aborting ...')
        
        trfired = squeeze_all_triggers(trmatched)
        new_st_status_entry()
        
        new_trace_entry(trf=trfired, final=final)
        set_st_status(final=final)
        
        return "OK"
        
            

    #-- Updating an WED-state (BEFORE UPDATE)---------------------------------------------------------------------------
    elif TD['event'] in ['UPDATE']:
        
        final, excpt = get_st_status(TD['new']['wid'])
        
        if final and not excpt:
            plpy.error('Cannot modify a final WED-state !')
        
        #-- token was provided
        if TD['new']['var_uptkn']:
            
            #--ignore token lookup on job_pool if uptkn='exception' -------------------------
            if TD['new']['var_uptkn'].lower() != 'exception': 

                job = find_job(TD['new']['var_uptkn'])
                
                if not job:
                    plpy.error('Job not found, not locked, expired or already completed, aborting ...')
                elif TD['new']['wid'] != job['wid']:
                    plpy.error('invalid WED-flow instance id (wid) for provided uptkn')
            
            #--FIX ME !!!
            else:
                if not excpt:
                    plpy.error('Current WED-state is not an exception !')
                    
                job = {'tgid':False, 'wid':TD['new']['wid']}

            rtrg = running_triggers(TD['new']['wid'])
            cond_set, final = pred_match(k,v)
            
            #--no running triggers, not fired any new transitions and is not a final state 
            if (not rtrg) and (not cond_set):
                plpy.warning('INCONSISTENT WED-state DETECTED !!!')
                new_trace_entry(k,v,job['tgid'],excpt=True,final=True)
                set_st_status(job['wid'],excpt=True)


            elif final:
                if len(rtrg):
                    plpy.error('There are pending WED-transitions, refusing to set a final WED-state!')
                else:
                    new_trace_entry(k,v,job['tgid'],final=True)
                    set_st_status(job['wid'])
                    plpy.info('Final WED-state reached!')

            else:
                fired = squeeze_the_trigger(cond_set,rtrg)
                new_trace_entry(k,v,job['tgid'],tgid_fired=fired)
                set_st_status(job['wid'],final=False)
                
                        
        else:
            plpy.error('token needed to update wed_flow')
            
        return "OK"
    
    else:
        return "SKIP"
        
    #--(END) TRIGGER CODE ----------------------------------------------------------------------------------------------    
$kt$ LANGUAGE plpython3u SECURITY DEFINER;

DROP TRIGGER IF EXISTS kernel_trigger_aft ON wed_flow;
CREATE TRIGGER kernel_trigger_aft
AFTER INSERT OR UPDATE ON wed_flow
    FOR EACH ROW EXECUTE PROCEDURE kernel_function();
    
------------------------------------------------------------------------------------------------------------------------
-- Lock a job from job_pool seting locked=True and ti = CURRENT_TIMESTAMP
CREATE OR REPLACE FUNCTION set_job_lock() RETURNS TRIGGER AS $pv$
    
    from datetime import datetime
       
    #--plpy.info(TD['new'])
    #--plpy.info(TD['old'])
   
    if TD['old']['locked']:
        #--aborted a previously locked job
        if TD['new']['aborted'] and not TD['old']['aborted']:
            TD['new'] = TD['old']
            TD['new']['aborted'] = True
            TD['new']['tf'] = datetime.now()
        else:
            plpy.error('Job \''+TD['new']['uptkn']+'\' already locked or aborted, aborting ...')
    
    elif TD['new']['locked']:
        #-- allow update only on 'locked' an 'lckid' columns
        lckid = TD['new']['lckid']
        TD['new'] = TD['old']
        TD['new']['lckid'] = lckid
        TD['new']['locked'] = True
        TD['new']['aborted'] = False
        TD['new']['ti'] = datetime.now()
    else:
        return "SKIP"   
    
    return "MODIFY"  
    
$pv$ LANGUAGE plpython3u SECURITY DEFINER;

DROP TRIGGER IF EXISTS lock_job ON job_pool;
CREATE TRIGGER lock_job
BEFORE UPDATE ON job_pool
    FOR EACH ROW EXECUTE PROCEDURE set_job_lock();

------------------------------------------------------------------------------------------------------------------------
-- Validate predicate (cpred) and final condition on WED_trig table
CREATE OR REPLACE FUNCTION wed_trig_validation_bfe() RETURNS TRIGGER AS $wtv$
    
    if TD['event'] in ['INSERT','UPDATE']:       
        import re
            
        fbdtkn = re.compile(r'CREATE|DROP|ALTER|GRANT|REVOKE|SELECT|INSERT|UPDATE|DELETE|;',re.I)        
        found = fbdtkn.search(TD['new']['cpred'])
        if found:
            plpy.error('Forbidden character or SQL keyword found in cpred expression: '+ found.group(0))
            #--return "SKIP"
        
        if TD['new']['trname']:
            trname = re.compile(r'^_')
            sysname = trname.search(TD['new']['trname'])
            if sysname:
                plpy.error('trname must not start with an underscore character !')
                #--return "SKIP"
        
        if TD['new']['cfinal']:
            TD['new']['trname'] = TD['new']['tgname'] = TD['new']['cname'] = '_FINAL'
            TD['new']['timeout'] = None
            return "MODIFY"
        else:
            return "OK"  
    
$wtv$ LANGUAGE plpython3u SECURITY DEFINER;

DROP TRIGGER IF EXISTS wed_trig_trg_bfe ON wed_trig;
CREATE TRIGGER wed_trig_trg_bfe
BEFORE INSERT OR UPDATE ON wed_trig
    FOR EACH ROW EXECUTE PROCEDURE wed_trig_validation_bfe();

--RESET ROLE;


