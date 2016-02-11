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
            raise psycopg2.DataError('WED-transition not found')
        
        return curs.fetchone()[0]
            
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
            return 1

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
                self.perform_transaction(data[0])
        job_conn.close()       

    #-------------------------------------------------------------------------------------------------------------------
    def perform_transaction(self,wid):
        try:
            job_conn = psycopg2.connect(self.dbs)
        except Exception as e:
            print(e)
            return 0
        
        curs = job_conn.cursor()
        
        # Try to open a transaction and lock the WED-flow instance wid, with the WED-state matching wed_cond
        try:
            curs.execute('SELECT * FROM wedflow where id=%s AND '+self.wed_cond+' FOR UPDATE NOWAIT ',[wid])
        except Exception as e:
            if not job_conn:
                print ('[\033[33m%s\033[0m] Connection closed by database (possible due to WED-transaction timeout): %s' %(self.trname,wid, e))
            else:
                print ('[\033[33m%s\033[0m] Instance %d already locked: %s' %(self.trname,wid, e))
                job_conn.close()
            return 0
        
        if not curs.rowcount:
            print('[\033[33m%s\033[0m] Instance %d: WED-condition missmatch (maybe this WED-state was already processed by another worker)' %(self.trname,wid))
            job_conn.close()
            return 0
        else:
            print('[\033[33m%s\033[0m] Instance %d LOCKED !' %(self.trname, wid))
        
        #Perform WED-transaction defined by wed_trans()
        print('[\033[33m%s\033[0m] Instance %d : performing WED-transaction ...' %(self.trname, wid))
        
        wed_state = self.wed_trans()
        
        try:
            curs.execute('UPDATE wedflow SET '+wed_state+' WHERE id=%s; COMMIT',[wid])
        except Exception as e:
            print ('[\033[33m%s\033[0m] Instance %d : %s' %(self.trname,wid, e))
            return 0
        else:
            print ('[\033[33m%s\033[0m] Instance %d updated !' %(self.trname,wid))
            job_conn.close()
            return 1  
        
        return 0     
    
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
        print("[\033[33m%s\033[0m] Initializing: looking for pending jobs..." %(self.trname))
        self.job_lookup()
        
        while 1:
            if select.select([conn],[],[],self.wkupint) == ([],[],[]):
                print("[\033[33m%s\033[0m] Timeout: looking for pending jobs..." %(self.trname))
                self.job_lookup()
            else:
                conn.poll()

                while conn.notifies:
                    notify = conn.notifies.pop(0)
                    print("[\033[33m%s\033[0m] Got NOTIFY: %d, %s, %s" %(self.trname,notify.pid, notify.channel, notify.payload))
                    job = json.loads(notify.payload)
                    self.perform_transaction(job['wid'])

