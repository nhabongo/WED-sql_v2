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
    
    def __init__(self,trname,dbs):
        self.trname = trname
        self.dbs = dbs
        self.wed_cond = self.get_wed_cond(trname)
    #-------------------------------------------------------------------------------------------------------------------
    @staticmethod
    def get_wed_cond(trname):
        #TODO
        #get WED-condition from database
        return "a1='r'"
    #-------------------------------------------------------------------------------------------------------------------
    @abstractmethod
    def wed_trans(self):
        pass
    #-------------------------------------------------------------------------------------------------------------------    
    def job_lookup(self):
        try:
            job_conn = psycopg2.connect(self.dbs)
        except Exception as e:
            print(e)
            sys.exit(1)

        #Cursor as a dict()
        #curs = job_conn.cursor(cursor_factory=psycopg2.extras.DictCursor)
        curs = job_conn.cursor()
        
        try:
            curs.execute('SELECT id FROM wedflow where '+self.wed_cond)
        except Exception as e:
            print ('[\033[33m%s\033[0m] select error: %s' %(self.trname,e))
        else:
            if not curs.rowcount:
                print('[\033[33m%s\033[0m] Nothing to do, going back to sleep.' %(self.trname))
            for data in curs.fetchall():
                if self.job_lock(data[0],curs):
                    wed_state = self.wed_trans()
                    if self.job_commit(data[0],curs,wed_state):
                        time.sleep(5)
                        job_conn.commit()
                    else:
                        job_conn.rollback()
                else:
                    job_conn.rollback()

    #-------------------------------------------------------------------------------------------------------------------                
    def job_notify(self,wid):
        try:
            job_conn = psycopg2.connect(self.dbs)
        except Exception as e:
            print(e)
            sys.exit(1)
        
        curs = job_conn.cursor()
        
        if self.job_lock(wid,curs):
            wed_state = self.wed_trans()
            if self.job_commit(wid,curs,wed_state):
                time.sleep(5)
                job_conn.commit()
            else:
                job_conn.rollback()
        else:
            job_conn.rollback()

    #-------------------------------------------------------------------------------------------------------------------        
    def job_commit(self,wid,curs,wed_state):
        try:
            curs.execute('UPDATE wedflow SET '+wed_state+' WHERE id=%s',[wid])
        except Exception as e:
            print ('[\033[33m%s\033[0m] Instance %d : %s' %(self.trname,wid, e))
            return 0
        else:
            print ('[\033[33m%s\033[0m] Instance %d updated !' %(self.trname,wid))
            return 1 
    
    #-------------------------------------------------------------------------------------------------------------------
    def job_lock(self,wid,curs):
        try:
            curs.execute('SELECT * FROM wedflow where id=%s AND '+self.wed_cond+' FOR UPDATE NOWAIT ',[wid])
        except Exception as e:
            print ('[\033[33m%s\033[0m] Instance %d already locked: %s' %(self.trname,wid, e))
            return 0
        else:
            if curs.rowcount:
                print ('[\033[33m%s\033[0m] Instance %d LOCKED !' %(self.trname, wid))
                return 1
            else:
                print('[\033[33m%s\033[0m] Instance %d: WED-condition missmatch (maybe this WED-state was already processed by another worker)' %(self.trname,wid))
                return 0     
    
    #-------------------------------------------------------------------------------------------------------------------
    def run(self):
        try:
            conn = psycopg2.connect(self.dbs)
        except Exception as e:
            print(e)
            
        conn.set_isolation_level(psycopg2.extensions.ISOLATION_LEVEL_AUTOCOMMIT)

        curs = conn.cursor()
        curs.execute("LISTEN "+self.trname)
        
        print("Listening on channel '\033[33m%s\033[0m'" %(self.trname))
        print("[\033[33m%s\033[0m] Initializing: looking for pending jobs..." %(self.trname))
        self.job_lookup()
        
        while 1:
            if select.select([conn],[],[],50) == ([],[],[]):
                print("[\033[33m%s\033[0m] Timeout: looking for pending jobs..." %(self.trname))
                self.job_lookup()
            else:
                conn.poll()

                while conn.notifies:
                    notify = conn.notifies.pop(0)
                    print("[\033[33m%s\033[0m] Got NOTIFY: %d, %s, %s" %(self.trname,notify.pid, notify.channel, notify.payload))
                    job = json.loads(notify.payload)
                    self.job_notify(job['wid'])

