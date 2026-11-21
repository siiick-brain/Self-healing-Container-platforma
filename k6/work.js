import http from 'k6/http';

export const options = {
  scenarios: {
    work: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.RATE || 10),
      timeUnit: '1s',
      duration: __ENV.DURATION || '2m',
      preAllocatedVUs: 10,
      maxVUs: 50,
    },
  },
};

export default function () {
  http.get(`${__ENV.WORK_URL || 'http://127.0.0.1:8080'}/work`, { timeout: '1s' });
}
