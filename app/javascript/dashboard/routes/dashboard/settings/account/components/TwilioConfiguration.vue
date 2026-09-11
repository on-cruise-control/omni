<script setup>
import { ref, reactive, onMounted } from 'vue';
import { useI18n } from 'vue-i18n';
import { useVuelidate } from '@vuelidate/core';
import { required } from '@vuelidate/validators';
import { useAlert } from 'dashboard/composables';
import twilioConfigurationAPI from 'dashboard/api/twilioConfiguration';

import SectionLayout from './SectionLayout.vue';
import WithLabel from 'v3/components/Form/WithLabel.vue';
import NextInput from 'dashboard/components-next/input/Input.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
import ConfirmationModal from 'dashboard/components/widgets/modal/ConfirmationModal.vue';

const { t } = useI18n();

const isSubmitting = ref(false);
const isDeleting = ref(false);
const isLoading = ref(true);
const isConfigured = ref(false);
const confirmDialogRef = ref(null);

const formState = reactive({
  accountSid: '',
  authToken: '',
  phoneNumber: '',
});

const MIN_PHONE_DIGITS = 10;
const MAX_PHONE_DIGITS = 13;

const digitCount = value => value.replace(/\D/g, '').length;

const isValidPhoneNumber = value => {
  if (!/^\+?\d+$/.test(value)) return false;
  const count = digitCount(value);
  return count >= MIN_PHONE_DIGITS && count <= MAX_PHONE_DIGITS;
};

const validations = {
  accountSid: { required },
  authToken: { required },
  phoneNumber: {
    required,
    isValidPhoneNumber,
  },
};

const v$ = useVuelidate(validations, formState, { $scope: false });

const onPhoneNumberKeydown = event => {
  const { key, ctrlKey, metaKey } = event;
  const isControlKey = key.length > 1 || ctrlKey || metaKey; // Backspace, Tab, arrows, copy/paste shortcuts, etc.
  if (isControlKey) return;

  const isPlusAtStart = key === '+' && formState.phoneNumber.length === 0;
  const isDigit = /\d/.test(key);

  if (isDigit && digitCount(formState.phoneNumber) >= MAX_PHONE_DIGITS) {
    event.preventDefault();
    return;
  }

  if (!isDigit && !isPlusAtStart) {
    event.preventDefault();
  }
};

const onPhoneNumberInput = () => {
  const sanitized = formState.phoneNumber.replace(/[^\d+]/g, '');
  const leadingPlus = sanitized.startsWith('+') ? '+' : '';
  const digits = sanitized.replace(/\+/g, '').slice(0, MAX_PHONE_DIGITS);
  formState.phoneNumber = leadingPlus + digits;
};

const loadTwilioConfiguration = async () => {
  try {
    isLoading.value = true;
    const response = await twilioConfigurationAPI.get();
    const configuration = response.data;

    if (configuration.id) {
      formState.accountSid = configuration.account_sid || '';
      formState.phoneNumber = configuration.phone_number || '';
      formState.authToken = configuration.auth_token || '';
      isConfigured.value = true;
    }
  } catch (error) {
    useAlert(t('GENERAL_SETTINGS.FORM.TWILIO_CONFIGURATION.API.ERROR_LOADING'));
  } finally {
    isLoading.value = false;
  }
};

const handleSubmit = async () => {
  v$.value.$touch();
  if (v$.value.$invalid) return;

  try {
    isSubmitting.value = true;
    const payload = {
      account_sid: formState.accountSid,
      phone_number: formState.phoneNumber,
      auth_token: formState.authToken,
    };

    const response = await twilioConfigurationAPI.update(payload);
    formState.authToken = response.data.auth_token || '';
    formState.phoneNumber = response.data.phone_number || '';
    isConfigured.value = true;
    useAlert(t('GENERAL_SETTINGS.FORM.TWILIO_CONFIGURATION.API.SUCCESS'));
  } catch (error) {
    const errorMessage =
      error.response?.data?.errors?.[0] ||
      t('GENERAL_SETTINGS.FORM.TWILIO_CONFIGURATION.API.ERROR');
    useAlert(errorMessage);
  } finally {
    isSubmitting.value = false;
  }
};

const handleDelete = async () => {
  const confirmed = await confirmDialogRef.value.showConfirmation();
  if (!confirmed) return;

  try {
    isDeleting.value = true;
    await twilioConfigurationAPI.delete();
    formState.accountSid = '';
    formState.authToken = '';
    formState.phoneNumber = '';
    isConfigured.value = false;
    v$.value.$reset();
    useAlert(t('GENERAL_SETTINGS.FORM.TWILIO_CONFIGURATION.DELETE.SUCCESS'));
  } catch (error) {
    useAlert(t('GENERAL_SETTINGS.FORM.TWILIO_CONFIGURATION.DELETE.ERROR'));
  } finally {
    isDeleting.value = false;
  }
};

onMounted(() => {
  loadTwilioConfiguration();
});
</script>

<template>
  <SectionLayout
    :title="t('GENERAL_SETTINGS.FORM.TWILIO_CONFIGURATION.TITLE')"
    :description="t('GENERAL_SETTINGS.FORM.TWILIO_CONFIGURATION.NOTE')"
  >
    <form v-if="!isLoading" class="grid gap-4" @submit.prevent="handleSubmit">
      <WithLabel
        name="twilio-account-sid"
        :label="
          t('GENERAL_SETTINGS.FORM.TWILIO_CONFIGURATION.ACCOUNT_SID.LABEL')
        "
        :has-error="v$.accountSid.$error"
        :error-message="
          t('GENERAL_SETTINGS.FORM.TWILIO_CONFIGURATION.ACCOUNT_SID.ERROR')
        "
      >
        <NextInput
          v-model="formState.accountSid"
          type="text"
          class="w-full"
          :placeholder="
            t(
              'GENERAL_SETTINGS.FORM.TWILIO_CONFIGURATION.ACCOUNT_SID.PLACEHOLDER'
            )
          "
          @blur="v$.accountSid.$touch"
        />
      </WithLabel>

      <WithLabel
        name="twilio-auth-token"
        :label="
          t('GENERAL_SETTINGS.FORM.TWILIO_CONFIGURATION.AUTH_TOKEN.LABEL')
        "
        :has-error="v$.authToken.$error"
        :error-message="
          t('GENERAL_SETTINGS.FORM.TWILIO_CONFIGURATION.AUTH_TOKEN.ERROR')
        "
      >
        <NextInput
          v-model="formState.authToken"
          type="text"
          class="w-full"
          :placeholder="
            t(
              'GENERAL_SETTINGS.FORM.TWILIO_CONFIGURATION.AUTH_TOKEN.PLACEHOLDER'
            )
          "
          @blur="v$.authToken.$touch"
        />
      </WithLabel>

      <WithLabel
        name="twilio-phone-number"
        :label="
          t('GENERAL_SETTINGS.FORM.TWILIO_CONFIGURATION.PHONE_NUMBER.LABEL')
        "
        :help-message="
          t('GENERAL_SETTINGS.FORM.TWILIO_CONFIGURATION.PHONE_NUMBER.HELP')
        "
        :has-error="v$.phoneNumber.$error"
        :error-message="
          t('GENERAL_SETTINGS.FORM.TWILIO_CONFIGURATION.PHONE_NUMBER.ERROR')
        "
      >
        <NextInput
          v-model="formState.phoneNumber"
          type="tel"
          class="w-full"
          :placeholder="
            t(
              'GENERAL_SETTINGS.FORM.TWILIO_CONFIGURATION.PHONE_NUMBER.PLACEHOLDER'
            )
          "
          @keydown="onPhoneNumberKeydown"
          @input="onPhoneNumberInput"
          @blur="v$.phoneNumber.$touch"
        />
      </WithLabel>

      <div class="flex gap-2">
        <NextButton blue type="submit" :is-loading="isSubmitting">
          {{ t('GENERAL_SETTINGS.FORM.TWILIO_CONFIGURATION.SUBMIT_BUTTON') }}
        </NextButton>
        <NextButton
          v-if="isConfigured"
          type="button"
          ruby
          :is-loading="isDeleting"
          @click="handleDelete"
        >
          {{ t('GENERAL_SETTINGS.FORM.TWILIO_CONFIGURATION.DELETE.BUTTON') }}
        </NextButton>
      </div>
    </form>

    <woot-loading-state v-else />
  </SectionLayout>

  <ConfirmationModal
    ref="confirmDialogRef"
    :title="
      t('GENERAL_SETTINGS.FORM.TWILIO_CONFIGURATION.DELETE.CONFIRM_TITLE')
    "
    :description="
      t('GENERAL_SETTINGS.FORM.TWILIO_CONFIGURATION.DELETE.CONFIRM')
    "
    :confirm-label="
      t('GENERAL_SETTINGS.FORM.TWILIO_CONFIGURATION.DELETE.BUTTON')
    "
    :cancel-label="
      t('GENERAL_SETTINGS.FORM.TWILIO_CONFIGURATION.DELETE.CANCEL')
    "
  />
</template>
