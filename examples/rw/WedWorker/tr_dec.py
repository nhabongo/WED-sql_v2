from BaseWorker import BaseClass
import sys,time

class MyWorker(BaseClass):
    
    #trname and dbs variables are static in order to conform with the definition of wed_trans()    
    trname = 'tr_rw'
    dbs = 'user=rw dbname=rw application_name=ww-tr_rw_dec'
    wakeup_interval = 5
    
    def __init__(self):
        super().__init__(MyWorker.trname,MyWorker.dbs,MyWorker.wakeup_interval)
        
    def wed_trans(self,payload):
        #time.sleep(1)
        
        for attr in payload.keys():
            if payload[attr] == '1':
                dec = 'a'+str(int(attr[1])-1)
                break
        
        return attr+"='0', "+dec+"='1'"
        
w = MyWorker()

try:
    w.run()
except KeyboardInterrupt:
    print()
    sys.exit(0)

