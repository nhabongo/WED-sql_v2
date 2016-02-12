SET ROLE wed_admin;

--select a.datid,a.datname,j.trname,l.locktype,l.classid,l.objid,a.pid,a.xact_start,j.timeout,a.query from pg_stat_activity a join pg_locks l on a.pid = l.pid and l.locktype='advisory' and l.granted and a.datname= current_database() join job_pool j on l.classid = j.wid and l.objid=j.tgid;

select l.pid from pg_stat_activity a join pg_locks l on a.pid = l.pid and l.locktype='advisory' and l.granted and a.datname= current_database() join job_pool j on l.classid = j.wid and l.objid=j.tgid where (a.xact_start + j.timeout) < now();

CREATE OR REPLACE FUNCTION job_inspector () RETURNS bool AS 
$$
    from datetime import datetime
    from os import urandom
    import hashlib
    
    #--Generates new instance trigger token ----------------------------------------------------------------------------
    def new_uptkn(trigger_name):
        salt = urandom(5)
        hash = hashlib.md5(salt + trigger_name)
        return hash.hexdigest()
    #-------------------------------------------------------------------------------------------------------------------
    
    now = plpy.quote_literal(str(datetime.now()))
    
    try:
        rows = plpy.execute('select t.tgname, t.tgid, j.wid, j.uptkn, j.tout ' +
                            'from job_pool j inner join wed_trig t on t.tgid = j.tgid ' + 
                            'where j.tf is null and ('+now+'::timestamp - j.ti) > j.tout')
    except plpy.SPIError as e:
        plpy.error('JOB_POOL scanning: '+str(e))
    else:
        if not rows:
            return False
        
        try:
            with plpy.subtransaction():
                plpy.execute('alter table job_pool disable trigger lock_job')
                for r in rows:
                    plpy.execute('update job_pool set aborted=TRUE, tf='+now+'::timestamp where uptkn='+
                                 plpy.quote_literal(r['uptkn']))
                    plpy.execute('insert into job_pool (tgid,wid,uptkn,tout) VALUES ' +
                                 str((r['tgid'],r['wid'],new_uptkn(r['tgname'].encode('utf-8')),r['tout'])))
                plpy.execute('alter table job_pool enable trigger lock_job')
        except plpy.SPIError as e:
            plpy.error('JOB_POOL inserting: '+str(e))
    return True
    
$$ LANGUAGE plpython3u;

CREATE OR REPLACE FUNCTION job_lock(uptkn pg_catalog.text, lckid pg_catalog.text) RETURNS bool AS
$$
    try:
        if lckid:
            res = plpy.execute('update job_pool set locked=TRUE, lckid='+plpy.quote_literal(lckid)+' where uptkn='+plpy.quote_literal(uptkn))
        else:
            res = plpy.execute('update job_pool set locked=TRUE where uptkn='+plpy.quote_literal(uptkn)) 
    except plpy.SPIError as e:
        plpy.error('job_lock error : '+str(e))
    
    return True if res.nrows() else False

$$ LANGUAGE plpython3u SECURITY DEFINER;

CREATE OR REPLACE FUNCTION job_abort(uptkn pg_catalog.text) RETURNS bool AS
$$
    try:
        res = plpy.execute('update job_pool set aborted=TRUE where uptkn='+plpy.quote_literal(uptkn))
    
    except plpy.SPIError as e:
        plpy.error('job_lock error : '+str(e))
    
    return True if res.nrows() else False

$$ LANGUAGE plpython3u SECURITY DEFINER;

RESET ROLE; 
