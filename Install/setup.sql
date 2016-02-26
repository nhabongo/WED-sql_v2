--on template1 database
REVOKE ALL ON DATABASE template1 FROM public;
REVOKE ALL ON SCHEMA public FROM public;
GRANT ALL ON SCHEMA public TO postgres;
CREATE LANGUAGE plpython3u;

--FOR DEBUG POURPOSE ONLY
--CREATE ROLE wed_admin WITH superuser noinherit;
--GRANT wed_admin TO wedflow;
