import http from "k6/http";
import { sleep, check } from "k6";
import { Counter } from "k6/metrics";

let ErrorCount = new Counter("errors");

const N_FOG = 16;
const N_EDGE_PER_FOG = 6;
let ALL_EDGE_NODES = false;
let IP_SKIP = ALL_EDGE_NODES ? 1 : N_EDGE_PER_FOG;

const START_NODE = 3 + N_FOG;
const END_NODE = START_NODE + N_EDGE_PER_FOG * N_FOG - 1;

const VUS_PER_EDGE_REGION = 300;

const TOTAL_VUS = VUS_PER_EDGE_REGION * N_FOG;

export let options = {
  stages: [
    { duration: "1m", target: TOTAL_VUS },
    { duration: "3m", target: TOTAL_VUS },
    { duration: "1m", target: 0 },
  ],
};


function getIP(vu) {
  let totalIPs = Math.floor((END_NODE - START_NODE + 1) / IP_SKIP);
  let nodeIndex = (vu-1) % totalIPs;
  return `172.20.0.${START_NODE + (nodeIndex * IP_SKIP)}`;
}

export default function () {
  let ip = getIP(__VU);
  let url = `http://${ip}/matmul`;

  let params = {
    headers: {
      "Content-Type": "application/json",
    },
    timeout: 60000,  
  };

  let payload = JSON.stringify({
    n: 1000,
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
