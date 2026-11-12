# Turn dbt run_results.json and Athena GetQueryExecution JSON into TSV rows:
# status, bytes, query id, statement type
def num:
  if . == null then 0
  elif type == "number" then .
  elif type == "string" and test("^[0-9]+$") then tonumber
  else 0
  end;

def norm_status:
  if . == null then "success"
  else
    (ascii_downcase) as $s
    | if ($s == "succeeded" or $s == "success" or $s == "pass" or $s == "ok") then "success"
      elif ($s == "failed" or $s == "error" or $s == "fail") then "error"
      else $s
      end
  end;

def rows:
  (
    (.results // [])[]?
    | {
        status: (.status | norm_status),
        bytes: ((.adapter_response.data_scanned_in_bytes // .adapter_response.bytes_scanned // .adapter_response.DataScannedInBytes // 0) | num),
        qid: (.adapter_response.query_id // .adapter_response.query_execution_id // .adapter_response.QueryExecutionId // ""),
        statement: (.adapter_response.statement_type // .adapter_response.StatementType // "UNKNOWN")
      }
  ),
  (
    if .QueryExecution then
      .QueryExecution
      | {
          status: (.Status.State | norm_status),
          bytes: ((.Statistics.DataScannedInBytes // 0) | num),
          qid: (.QueryExecutionId // ""),
          statement: (.StatementType // "UNKNOWN")
        }
    else empty end
  );

rows | [.status, (.bytes | tostring), .qid, .statement] | @tsv
