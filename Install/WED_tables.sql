--multiples instance of a particular wedflow

DROP TABLE IF EXISTS WED_attr;
DROP TABLE IF EXISTS WED_trace;
DROP TABLE IF EXISTS JOB_POOL;
DROP SEQUENCE IF EXISTS job_id_gen;
DROP TABLE IF EXISTS WED_trig;
DROP TABLE IF EXISTS ST_STATUS;
DROP TABLE IF EXISTS WED_flow CASCADE;
--DROP SEQUENCE IF EXISTS wed_cond_cid;
--CREATE SEQUENCE wed_cond_cid;

-- An '*' means that WED-attributes columns will be added dynamicaly after an INSERT on WED-attr table
--*WED-flow instances
CREATE TABLE WED_flow (
    wid     SERIAL PRIMARY KEY
);

CREATE TABLE WED_attr (
    aid     SERIAL NOT NULL,
    aname    TEXT NOT NULL,
    adv   TEXT
);
-- name must be unique 
CREATE UNIQUE INDEX wed_attr_lower_name_idx ON WED_attr (lower(aname));

-- use wed_pred to allow two or more diferent conditions to fire the same transition (validate trname !~ '^_')
CREATE TABLE WED_trig (
    tgid     SERIAL PRIMARY KEY,
    tgname  TEXT NOT NULL DEFAULT '',
    trname  TEXT NOT NULL,
    cname  TEXT NOT NULL DEFAULT '',
    cpred  TEXT NOT NULL DEFAULT '',
    cfinal BOOL NOT NULL DEFAULT FALSE,
    timeout    INTERVAL DEFAULT '00:01:00'
);
CREATE UNIQUE INDEX wed_trig_lower_trname_idx ON WED_trig (lower(trname));
CREATE UNIQUE INDEX wed_trig_cfinal_idx ON WED_trig (cfinal) WHERE cfinal is TRUE;


--Running transitions (set locked and ti)
CREATE SEQUENCE job_id_gen;
CREATE TABLE JOB_POOL (
    jid     BIGINT PRIMARY KEY DEFAULT nextval('job_id_gen'::regclass),
    wid     INTEGER NOT NULL ,
    trname   TEXT NOT NULL,
    lckid   TEXT,
    timeout    INTERVAL NOT NULL,
    FOREIGN KEY (wid) REFERENCES WED_flow (wid) ON DELETE RESTRICT
);     

--Fast final WED-state detection
CREATE TABLE ST_STATUS (
    wid     INTEGER PRIMARY KEY,
    final   BOOL NOT NULL DEFAULT FALSE,
    excpt   BOOL NOT NULL DEFAULT FALSE,
    FOREIGN KEY (wid) REFERENCES WED_flow (wid) ON DELETE RESTRICT
);

--*WED-trace keeps the execution history for all instances
CREATE TABLE WED_trace (
    wid     INTEGER,
    tgid_wrote    INTEGER DEFAULT NULL,
    tgid_fired    INTEGER[] DEFAULT NULL,
    final    BOOL NOT NULL DEFAULT FALSE,
    excpt    BOOL NOT NULL DEFAULT FALSE,
    tstmp      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (wid) REFERENCES WED_flow (wid) ON DELETE RESTRICT,
    FOREIGN KEY (tgid_wrote) REFERENCES WED_trig (tgid) ON DELETE RESTRICT
);
