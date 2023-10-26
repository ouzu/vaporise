import http from "k6/http";
import { sleep, check } from "k6";
import { Counter } from "k6/metrics";
import exec from 'k6/execution';

let ErrorCount = new Counter("errors");

const N_FOG = 3;
const N_EDGE_PER_FOG = 3;

const TOTAL_EDGE_NODES = N_FOG * N_EDGE_PER_FOG;

let ALL_EDGE_NODES = false;
let IP_SKIP = ALL_EDGE_NODES ? 1 : N_EDGE_PER_FOG;

const START_NODE = 3 + N_FOG;
const END_NODE = START_NODE + N_EDGE_PER_FOG * N_FOG - 1;

const REQUESTS_PER_SECOND_PER_NODE = 1;
const TOTAL_REQUESTS_PER_SECOND = REQUESTS_PER_SECOND_PER_NODE * TOTAL_EDGE_NODES;

export const options = {
  discardResponseBodies: true,
  scenarios: {
    contacts: {
      executor: 'constant-arrival-rate',
      duration: '10m',
      rate: N_EDGE_PER_FOG,
      timeUnit: '1s',
      preAllocatedVUs: N_EDGE_PER_FOG * 60,
    },
  }
};

function getIP(vu) {
  let totalIPs = Math.floor((END_NODE - START_NODE + 1) / IP_SKIP);
  let nodeIndex = (vu - 1) % totalIPs;
  return `172.20.0.${START_NODE + nodeIndex * IP_SKIP}`;
}

export default function () {
  //let ip = getIP(exec.vu.iterationInScenario);

  let ip = `172.20.0.${2 + N_FOG}`

  let url = `http://${ip}/matmul`;

  let params = {
    headers: {
      "Content-Type": "application/json",
    },
    timeout: 60000,
  };

  let payload = JSON.stringify({
    n: 1,
    metadata: "",
  });

  let res = http.post(url, payload, params);

  let resultCheck = check(res, {
    "status is 200": (r) => r.status === 200,
  });

  if (!resultCheck) {
    ErrorCount.add(1);
  }

  sleep(1);
}
