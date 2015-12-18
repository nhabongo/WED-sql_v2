from BaseWorker import BaseClass
import sys,time

class MyWorker(BaseClass):
    
    #trname and dbs variables are static in order to conform with the definition of wed_trans()    
    trname = 'tr1'
    dbs = 'user=wed_admin dbname=sandbox'
    
    def __init__(self):
        super().__init__(MyWorker.trname,MyWorker.dbs)
        
    def wed_trans(self):
        time.sleep(15)
        return "a1='d',a2='d'"
        
w = MyWorker()

try:
    w.run()
except KeyboardInterrupt:
    print()
    sys.exit(0)

