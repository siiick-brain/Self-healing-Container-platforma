import http from 'k6/http';
import { Counter } from 'k6/metrics';

const requests = new Counter('canary_requests');

export const options = {
  scenarios: {
    work: {
      executor: 'constant-arrival-rate',
      rate: 10,
      timeUnit: '1s',
      duration: '7m',
      preAllocatedVUs: 10,
      maxVUs: 50,
    },
  },
  thresholds: { dropped_iterations: ['count==0'] },
};

export default function () {
  const response = http.get('http://127.0.0.1:8080/work', {
    headers: { Host: 'canary-proof.localhost' },
    timeout: '2s',
  });
  let release = 'other';
  if (response.status === 503 && response.headers['X-Lab-Canary'] === 'bad') {
    release = 'bad';
  } else if (response.status === 200 && response.body === 'ok\n') {
    release = 'stable';
  }
  requests.add(1, { release });
}
