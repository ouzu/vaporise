import http from "k6/http";
import { sleep, check } from "k6";
import { Counter } from "k6/metrics";

let ErrorCount = new Counter("errors");

export let options = {
  stages: [
    { duration: "15s", target: 30, rate: "10/s" },
    { duration: "2m", target: 30, rate: "10/s" },
    { duration: "15s", target: 0 },
  ],
};

// Choose the range of IP addresses
const START_IP = 6;
const END_IP = 14;

// Helper function to get random IP in the range
function getRandomIP() {
  return `172.20.0.${Math.floor(
    Math.random() * (END_IP - START_IP + 1) + START_IP
  )}`;
}

export default function () {
  let ip = getRandomIP();
  let url = `http://${ip}/matmul`;

  let params = {
    headers: {
      "Content-Type": "application/json",
    },
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

  sleep(1); // Adjust sleep as needed
}
