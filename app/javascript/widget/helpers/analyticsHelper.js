import { IFrameHelper } from 'widget/helpers/utils';

export const trackEvent = (eventName, eventParams = {}) => {
  // eslint-disable-next-line no-console
  console.log(`Courier widget: ASC event -> ${eventName}`, eventParams);
  IFrameHelper.sendMessage({
    event: 'asc-event',
    name: eventName,
    params: eventParams,
  });
};
