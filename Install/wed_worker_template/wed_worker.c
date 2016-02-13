/* -------------------------------------------------------------------------
 *
 * wed_worker.c
 *
 */
#include "postgres.h"

/* These are always necessary for a bgworker */
#include "miscadmin.h"
#include "postmaster/bgworker.h"
#include "storage/ipc.h"
#include "storage/latch.h"
#include "storage/lwlock.h"
#include "storage/proc.h"
#include "storage/shmem.h"

/* these headers are used by this particular worker's code */
#include "access/xact.h"
#include "executor/spi.h"
#include "fmgr.h"
#include "lib/stringinfo.h"
#include "pgstat.h"
#include "utils/builtins.h"
#include "utils/snapmgr.h"
#include "tcop/utility.h"

PG_MODULE_MAGIC;

PG_FUNCTION_INFO_V1(wed_worker_launch);

void		_PG_init(void);
void		wed_worker_main(Datum);

/* flags set by signal handlers */
static volatile sig_atomic_t got_sighup = false;
static volatile sig_atomic_t got_sigterm = false;

/* GUC variables */
static int	wed_worker_naptime = 1;
static int	wed_worker_total_workers = 1;
static char* wed_worker_db_name;


/*
 * Signal handler for SIGTERM
 *		Set a flag to let the main loop to terminate, and set our latch to wake
 *		it up.
 */
static void
wed_worker_sigterm(SIGNAL_ARGS)
{
	int			save_errno = errno;

	got_sigterm = true;
	if (MyProc)
		SetLatch(&MyProc->procLatch);

	errno = save_errno;
}

/*
 * Signal handler for SIGHUP
 *		Set a flag to tell the main loop to reread the config file, and set
 *		our latch to wake it up.
 */
static void
wed_worker_sighup(SIGNAL_ARGS)
{
	int			save_errno = errno;

	got_sighup = true;
	if (MyProc)
		SetLatch(&MyProc->procLatch);

	errno = save_errno;
}

/*
 * worker logic
 */
void
wed_worker_main(Datum main_arg)
{
	StringInfoData buf;
    
    
	/* Establish signal handlers before unblocking signals. */
	pqsignal(SIGHUP, wed_worker_sighup);
	pqsignal(SIGTERM, wed_worker_sigterm);

	/* We're now ready to receive signals */
	BackgroundWorkerUnblockSignals();

	/* Connect to our database */
	BackgroundWorkerInitializeConnection(wed_worker_db_name, NULL);

	elog(LOG, "%s initialized in: %s",
		 MyBgworkerEntry->bgw_name, wed_worker_db_name);

	initStringInfo(&buf);
	appendStringInfo(&buf, "SELECT trcheck()");

	/*
	 * Main loop: do this until the SIGTERM handler tells us to terminate
	 */
	while (!got_sigterm)
	{
		int			ret;
		int			rc;

		/*
		 * Background workers mustn't call usleep() or any direct equivalent:
		 * instead, they may wait on their process latch, which sleeps as
		 * necessary, but is awakened if postmaster dies.  That way the
		 * background process goes away immediately in an emergency.
		 */
		rc = WaitLatch(&MyProc->procLatch,
					   WL_LATCH_SET | WL_TIMEOUT | WL_POSTMASTER_DEATH,
					   wed_worker_naptime * 1000L);
		ResetLatch(&MyProc->procLatch);

		/* emergency bailout if postmaster has died */
		if (rc & WL_POSTMASTER_DEATH)
			proc_exit(1);

		/*
		 * In case of a SIGHUP, just reload the configuration.
		 */
		if (got_sighup)
		{
			got_sighup = false;
			ProcessConfigFile(PGC_SIGHUP);
		}

		/*
		 * Start a transaction on which we can run queries.  Note that each
		 * StartTransactionCommand() call should be preceded by a
		 * SetCurrentStatementStartTimestamp() call, which sets both the time
		 * for the statement we're about the run, and also the transaction
		 * start time.  Also, each other query sent to SPI should probably be
		 * preceded by SetCurrentStatementStartTimestamp(), so that statement
		 * start time is always up to date.
		 *
		 * The SPI_connect() call lets us run queries through the SPI manager,
		 * and the PushActiveSnapshot() call creates an "active" snapshot
		 * which is necessary for queries to have MVCC data to work on.
		 *
		 * The pgstat_report_activity() call makes our activity visible
		 * through the pgstat views.
		 */
		SetCurrentStatementStartTimestamp();
		StartTransactionCommand();
		SPI_connect();
		PushActiveSnapshot(GetTransactionSnapshot());
		pgstat_report_activity(STATE_RUNNING, buf.data);

		/* We can now execute queries via SPI */
		ret = SPI_execute(buf.data, false, 0);

		if (ret != SPI_OK_SELECT)
			elog(FATAL, "stored procedure trcheck() not found: error code %d", ret);

        elog(LOG, "%s : trcheck() done !", MyBgworkerEntry->bgw_name);
		/*
		 * And finish our transaction.
		 */
		SPI_finish();
		PopActiveSnapshot();
		CommitTransactionCommand();
		pgstat_report_activity(STATE_IDLE, NULL);
	}

	proc_exit(1);
}

/*
 * Entrypoint of this module.
 *
 * We register more than one worker process here, to demonstrate how that can
 * be done.
 */
void
_PG_init(void)
{
	BackgroundWorker worker;
	unsigned int i;
	
	/* Define wich database to attach  */
    DefineCustomStringVariable("wed_worker.db_name",
                              "WED-flow database to attach",
                              NULL,
                              &wed_worker_db_name,
                              __DB_NAME__,
                              PGC_SIGHUP,
                              0,
                              NULL,
                              NULL,
                              NULL);

	/* get the configuration */
	DefineCustomIntVariable("wed_worker.naptime",
							"Duration between each check (in seconds).",
							NULL,
							&wed_worker_naptime,
							10,
							1,
							INT_MAX,
							PGC_SIGHUP,
							0,
							NULL,
							NULL,
							NULL);

	if (!process_shared_preload_libraries_in_progress)
		return;

	DefineCustomIntVariable("wed_worker.total_workers",
							"Number of workers.",
							NULL,
							&wed_worker_total_workers,
							1,
							1,
							100,
							PGC_POSTMASTER,
							0,
							NULL,
							NULL,
							NULL);

	/* set up common data for all our workers */
	worker.bgw_flags = BGWORKER_SHMEM_ACCESS |
		BGWORKER_BACKEND_DATABASE_CONNECTION;
	worker.bgw_start_time = BgWorkerStart_RecoveryFinished;
	worker.bgw_restart_time = BGW_NEVER_RESTART;
	worker.bgw_main = wed_worker_main;
	worker.bgw_notify_pid = 0;
	/*
	 * Now fill in worker-specific data, and do the actual registrations.
	 */
	for (i = 1; i <= wed_worker_total_workers; i++)
	{
		snprintf(worker.bgw_name, BGW_MAXLEN, "ww[%s] %d", wed_worker_db_name, i);
		worker.bgw_main_arg = Int32GetDatum(i);
		RegisterBackgroundWorker(&worker);
	}
}

/*
 * Dynamically launch an SPI worker.
// */
//
//Datum
//wed_worker_launch(PG_FUNCTION_ARGS)
//{
//    int32		i = PG_GETARG_INT32(0);
//    text*       db_name = PG_GETARG_TEXT_P(1);
//    BackgroundWorker worker;
//    BackgroundWorkerHandle *handle;
//    BgwHandleStatus status;
//    pid_t		pid;
//    
//    elog(LOG, "dyn_launch: nargs = %d (%d, %s)", PG_NARGS(), i, tmp);
//    
//    worker.bgw_flags = BGWORKER_SHMEM_ACCESS |
//	    BGWORKER_BACKEND_DATABASE_CONNECTION;
//    worker.bgw_start_time = BgWorkerStart_RecoveryFinished;
//    worker.bgw_restart_time = BGW_NEVER_RESTART;
//    worker.bgw_main = NULL;		/* new worker might not have library loaded */
//    sprintf(worker.bgw_library_name, "wed_worker");
//    sprintf(worker.bgw_function_name, "wed_worker_main");
//    snprintf(worker.bgw_name, BGW_MAXLEN, "wed_worker %d", i);
//    worker.bgw_main_arg = Int32GetDatum(i);
//    /* set bgw_notify_pid so that we can use WaitForBackgroundWorkerStartup */
//    worker.bgw_notify_pid = MyProcPid;
//
//    if (!RegisterDynamicBackgroundWorker(&worker, &handle))
//	    PG_RETURN_NULL();
//
//    status = WaitForBackgroundWorkerStartup(handle, &pid);
//
//    if (status == BGWH_STOPPED)
//	    ereport(ERROR,
//			    (errcode(ERRCODE_INSUFFICIENT_RESOURCES),
//			     errmsg("could not start background process"),
//		       errhint("More details may be available in the server log.")));
//    if (status == BGWH_POSTMASTER_DIED)
//	    ereport(ERROR,
//			    (errcode(ERRCODE_INSUFFICIENT_RESOURCES),
//		      errmsg("cannot start background processes without postmaster"),
//			     errhint("Kill all remaining database processes and restart the database.")));
//    Assert(status == BGWH_STARTED);
//
//    PG_RETURN_INT32(pid);
//}
