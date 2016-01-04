/* wed_worker/wed_worker--1.0.sql */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION wed_worker" to load this file. \quit

-- Dynamic background laucher
--CREATE OR REPLACE FUNCTION wed_worker_launch(pg_catalog.int4, pg_catalog.text)
--RETURNS pg_catalog.int4 STRICT
--AS 'MODULE_PATHNAME'
--LANGUAGE C;
