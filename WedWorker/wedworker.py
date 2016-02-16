from BaseWorker import BaseClass
import sys

class MyWorker(BaseClass):
    
    #trname and dbs variables are static in order to conform with the definition of wed_trans()    
    trname = 'tr_aaa'
    dbs = 'user=aaa dbname=aaa application_name=ww-tr_aaa'
    wakeup_interval = 5
    
    def __init__(self):
        super().__init__(MyWorker.trname,MyWorker.dbs,MyWorker.wakeup_interval)
    
    # Compute the WED-transition and return a string as the new WED-state, using the SQL SET clause syntax 
    # Return None to abort transaction
    def wed_trans(self,payload):
        print (payload)
        
        return "a2='done', a3='ready', a4=(a4::integer+1)::text"
        #return None
        
w = MyWorker()

try:
    w.run()
except KeyboardInterrupt:
    print()
    sys.exit(0)

