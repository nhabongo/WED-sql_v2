--SET ROLE wed_admin;

CREATE OR REPLACE FUNCTION trcheck () RETURNS bool AS 
$$
    import time
    
    rv = False
    
    try:
        kill_list = plpy.execute('select l.pid from pg_stat_activity a join pg_locks l '+ 
                                 'on a.pid = l.pid and l.locktype=\'advisory\' and l.granted and a.datname= current_database() '+
                                 'join job_pool j on l.classid = j.wid and l.objid=j.tgid where (a.xact_start + j.timeout) < now()')
    except plpy.SPIError as e:
        plpy.error('TRCHECK ERROR: '+str(e))
    
    for job in kill_list:
        try:
            plpy.execute('select pg_terminate_backend('+str(job['pid'])+') as terminated')
        except plpy.SPIError as e:
            plpy.error(e)
        rv = True

    return rv
    
$$ LANGUAGE plpython3u;

CREATE OR REPLACE FUNCTION trigger_toggle(tgid integer) RETURNS bool AS
$$

    try:
        res = plpy.execute('update wed_trig set enabled = not enabled where tgid='+str(tgid)+' returning enabled')
    except plpy.SPIError as e:
        plpy.error(e)
    
    return res[0]['enabled']


$$ LANGUAGE plpython3u;

--RESET ROLE; 
