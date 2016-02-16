from abc import ABCMeta, abstractmethod
import select,sys,json,random
import psycopg2
import psycopg2.extensions
import psycopg2.extras
import time

class BaseClass(metaclass=ABCMeta):
    """
    Base class to implement a WED-worker
    - trname: WED-transition to executed by a Base sub-class
    - dbs: database connection string
    """
    
    def __init__(self,trname,dbs,wakeup_interval=60):
        self.trname = trname
        self.dbs = dbs
        self.wkupint = wakeup_interval
        self.wed_cond = self.__get_wed_cond(trname,dbs)

    #-------------------------------------------------------------------------------------------------------------------
    @staticmethod
    def __get_wed_cond(trname,dbs):

        job_conn = psycopg2.connect(dbs)
        curs = job_conn.cursor()
        curs.execute('select cpred from wed_trig where trname = %s',[trname])
        
        if curs.rowcount != 1:
            raise psycopg2.DataError('WED-transition "%s" not found' %(trname))
        
        return curs.fetchone()[0]
            
    #-------------------------------------------------------------------------------------------------------------------
    @abstractmethod
    def wed_trans(self,payload):
        pass

    #-------------------------------------------------------------------------------------------------------------------    
    def job_lookup(self):
        try:
            job_conn = psycopg2.connect(self.dbs)
        except Exception as e:
            print(e)
            return -1

        #Cursor as a dict()
        curs = job_conn.cursor(cursor_factory=psycopg2.extras.DictCursor)
        #curs = job_conn.cursor()
        
        try:
            curs.execute('SELECT * FROM job_pool where trname=%s', [self.trname])
        except Exception as e:
            print ('[\033[31m%s\033[0m] select error: %s' %(self.trname,e))
        else:
            if not curs.rowcount:
                print('[\033[37m%s\033[0m] Nothing to do, going back to sleep.' %(self.trname))
            else:
                for data in curs.fetchall():
                    self.perform_transaction(data)
        job_conn.close()       

    #-------------------------------------------------------------------------------------------------------------------
    def perform_transaction(self,data):
        try:
            job_conn = psycopg2.connect(self.dbs)
        except Exception as e:
            print(e)
            return -1
        
        curs = job_conn.cursor()
        
        print("[\033[37m%s\033[0m] Running WED-transition on wid=%d ..." %(self.trname,data['wid']),flush=True)
        try:
            curs.execute('select pg_try_advisory_xact_lock(%s,%s)',[data['wid'],data['tgid']])
        except Exception as e:
            print(e)
        else:
            got_lock = curs.fetchone()[0]
            if got_lock:
                new_wed_state = self.wed_trans(data['payload'])
                if not new_wed_state:
                    print("[\033[33m%s\033[0m] Aborting transaction ..." %(self.trname),flush=True)
                    job_conn.rollback()
                else:
                    try:
                        curs.execute('update wed_flow set '+new_wed_state+' where wid=%s',[data['wid']])
                    except Exception as e:
                        print(e)
                    else:
                        job_conn.commit()
                        print("[\033[32m%s\033[0m] wid=%d updated !" %(self.trname,data['wid']),flush=True)
            else:
                print("[\033[31m%s\033[0m] Could not get a lock on wid=%d !" %(self.trname,data['wid']),flush=True)
                        
        job_conn.close()
            
    
    #-------------------------------------------------------------------------------------------------------------------
    def run(self):
        try:
            conn = psycopg2.connect(self.dbs)
        except Exception as e:
            print(e)
            return
            
        conn.set_isolation_level(psycopg2.extensions.ISOLATION_LEVEL_AUTOCOMMIT)

        curs = conn.cursor()
        curs.execute("LISTEN "+self.trname)
        
        print("Listening on channel '\033[33m%s\033[0m'" %(self.trname))
        print("[\033[37m%s\033[0m] Initializing: looking for pending jobs..." %(self.trname))
        self.job_lookup()
        
        while 1:
            if select.select([conn],[],[],self.wkupint) == ([],[],[]):
                print("[\033[37m%s\033[0m] Timeout: looking for pending jobs..." %(self.trname))
                self.job_lookup()
            else:
                conn.poll()

                while conn.notifies:
                    notify = conn.notifies.pop(0)
                    print("[\033[37m%s\033[0m] Got NOTIFY: %d, %s, %s" %(self.trname,notify.pid, notify.channel, notify.payload))
                    job = json.loads(notify.payload)
                    job['payload'] = json.loads(job['payload'])
                    #TODO: send timout to wed_trans
                    self.perform_transaction(job)













