CREATE OR REPLACE FUNCTION sp_mark_step_finished(
IN _task_id int,
IN _step_name character varying,
IN _node_name character varying,
IN _exit_code int,
IN _user_cpu_ms bigint,
IN _system_cpu_ms bigint,
IN _duration_ms bigint,
IN _max_rss_kb int,
IN _max_vm_size_kb int,
IN _disk_read_b bigint,
IN _disk_write_b bigint,
IN _stdout_text CHARACTER VARYING,
IN _stderr_text CHARACTER VARYING
) RETURNS boolean AS $$
DECLARE runnable_task_ids int[];
DECLARE runnable_task_id int;
BEGIN

	IF (SELECT current_setting('transaction_isolation') NOT ILIKE 'REPEATABLE READ') THEN
		RAISE EXCEPTION 'The transaction isolation level has not been set to REPEATABLE READ as expected.' USING ERRCODE = 'UE001';
	END IF;

	UPDATE step
	SET status_id = CASE status_id
                        WHEN 1 THEN 6 -- Submitted -> Finished
                        WHEN 2 THEN 6 -- PendingStart -> Finished
                        WHEN 4 THEN 6 -- Running -> Finished
                        ELSE status_id
                    END,
	end_timestamp = now(),
	status_timestamp = CASE status_id
                           WHEN 1 THEN now()
                           WHEN 2 THEN now()
                           WHEN 4 THEN now()
                           ELSE status_timestamp
                       END,
	exit_code = _exit_code
	WHERE name = _step_name AND task_id = _task_id
	AND status_id != 6; -- Prevent resetting the status on serialization error retries.

	-- Make sure the statistics are inserted only once.
	IF NOT EXISTS (SELECT * FROM step_resource_log WHERE step_name = _step_name AND task_id = _task_id) THEN
		INSERT INTO step_resource_log(
		step_name,
		task_id,
		node_name,
		entry_timestamp,
		duration_ms,
		user_cpu_ms,
		system_cpu_ms,
		max_rss_kb,
		max_vm_size_kb,
		disk_read_b,
		disk_write_b,
		stdout_text,
		stderr_text)
		VALUES (
		_step_name,
		_task_id,
		_node_name,
		now(),
		_duration_ms,
		_user_cpu_ms,
		_system_cpu_ms,
		_max_rss_kb,
		_max_vm_size_kb,
		_disk_read_b,
		_disk_write_b,
		_stdout_text,
		_stderr_text);
	END IF;

	UPDATE task
	SET status_id = CASE status_id
                        WHEN 1 THEN 6 -- Submitted -> Finished
                        WHEN 4 THEN 6 -- Running -> Finished
                        ELSE status_id
                    END,
	status_timestamp = CASE status_id
                           WHEN 1 THEN now()
                           WHEN 4 THEN now()
                           ELSE status_timestamp
                       END
	WHERE id = _task_id
	AND status_id != 6 -- Prevent resetting the status on serialization error retries.
	AND NOT EXISTS (SELECT * FROM step WHERE task_id = _task_id AND status_id != 6); -- Check that all the steps have been finished.

	IF EXISTS (SELECT * FROM task WHERE id = _task_id AND status_id = 6) THEN
		INSERT INTO event(
		type_id,
		data,
		submitted_timestamp)
		SELECT
		2, -- TaskFinished
		('{"job_id":' || job.id || ', "processor_id":' || job.processor_id || ', "site_id":' || job.site_id || ', "task_id":' || _task_id || ', "module_short_name":"' || task.module_short_name || '"}') :: json,
		now()
		FROM job INNER JOIN task ON job.id = task.job_id WHERE task.id = _task_id;

		-- Get the list of tasks that depended on this one and were in status 3 NeedsInput
		WITH tasks_preceded AS (
			SELECT id, preceding_task_ids  FROM task WHERE
			_task_id = ANY(preceding_task_ids)  AND status_id = 3 -- NeedsInput
		)
		-- From the list of tasks determined above, get the list of tasks whose preceding tasks have all been completed and store the ids of the runnable tasks into an array
		SELECT array_agg(tasks_preceded.id) INTO runnable_task_ids FROM tasks_preceded
		WHERE NOT EXISTS (SELECT * FROM task WHERE task.id = ANY (tasks_preceded.preceding_task_ids) AND task.status_id != 6 /*Finished*/ );

		-- Update the tasks that can be run
		UPDATE task SET
			status_id = CASE status_id
                            WHEN 3 THEN 1 -- NeedsInput -> Submitted
                            ELSE status_id
                        END,
			status_timestamp = CASE status_id
                                   WHEN 3 THEN now()
                                   ELSE status_timestamp
                               END
		WHERE task.id = ANY(runnable_task_ids);

        IF runnable_task_ids IS NOT NULL THEN
            -- Add events for all the runnable tasks
            FOREACH runnable_task_id IN ARRAY runnable_task_ids
            LOOP
		    INSERT INTO event(
		    type_id,
		    data,
		    submitted_timestamp)
		    SELECT
		    1, -- TaskRunnable
		    ('{"job_id":' || job_id || ', "processor_id":' || job.processor_id || ', "task_id":' || runnable_task_id || '}') :: json,
		    now()
		    FROM job INNER JOIN task ON job.id = task.job_id WHERE task.id = runnable_task_id;
            END LOOP;
        END IF;

	END IF;

	RETURN EXISTS (SELECT *
	FROM task WHERE id = _task_id AND status_id = 6);

END;
$$ LANGUAGE plpgsql;
