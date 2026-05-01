// SPDX-License-Identifier: GPL-2.0
/*
 * Copyright (C) 2019-2021 Samsung Electronics Co. Ltd.
 */

#define pr_fmt(fmt) "[VIB] " fmt
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/hrtimer.h>
#include <linux/platform_device.h>
#include <linux/err.h>
#include <linux/delay.h>
#include <linux/slab.h>
#include <linux/vibrator/sec_vibrator.h>
#if IS_ENABLED(CONFIG_SEC_VIB_NOTIFIER)
#include <linux/vibrator/sec_vibrator_notifier.h>
#endif
#if IS_ENABLED(CONFIG_BATTERY_SAMSUNG)
#if defined(CONFIG_BATTERY_GKI)
#include <linux/battery/sec_battery_common.h>
#else
#include "../../battery/common/sec_charging_common.h"
#endif
#endif
#if defined(CONFIG_SEC_KUNIT)
#include "kunit_test/sec_vibrator_test.h"
#else
#define __visible_for_testing static
#endif

static const int  kMaxBufSize = 7;
static const int kMaxHapticStepSize = 7;
static const char *str_newline = "\n";

#define VIB_SHORT_OVERDRIVE_TIMEOUT_MS	20
#define VIB_TEMP_CACHE_TIMEOUT_MS	10000

static struct sec_vibrator_drvdata *g_ddata;

static char vib_event_cmd[MAX_STR_LEN_EVENT_CMD];

static const char sec_vib_event_cmd[EVENT_CMD_MAX][MAX_STR_LEN_EVENT_CMD] = {
	[EVENT_CMD_NONE]					= "NONE",
	[EVENT_CMD_FOLDER_CLOSE]				= "FOLDER_CLOSE",
	[EVENT_CMD_FOLDER_OPEN]					= "FOLDER_OPEN",
	[EVENT_CMD_ACCESSIBILITY_BOOST_ON]			= "ACCESSIBILITY_BOOST_ON",
	[EVENT_CMD_ACCESSIBILITY_BOOST_OFF]			= "ACCESSIBILITY_BOOST_OFF",
	[EVENT_CMD_TENT_CLOSE]					= "FOLDER_TENT_CLOSE",
	[EVENT_CMD_TENT_OPEN]					= "FOLDER_TENT_OPEN",
};

#if IS_ENABLED(CONFIG_SEC_VIB_NOTIFIER)
static struct vib_notifier_context vib_notifier;
static struct blocking_notifier_head sec_vib_nb_head = BLOCKING_NOTIFIER_INIT(sec_vib_nb_head);

int sec_vib_notifier_register(struct notifier_block *noti_block)
{
	int ret = 0;

	pr_info("%s\n", __func__);

	if (!noti_block)
		return -EINVAL;

	ret = blocking_notifier_chain_register(&sec_vib_nb_head, noti_block);
	if (ret < 0)
		pr_err("%s: failed(%d)\n", __func__, ret);

	return ret;
}
EXPORT_SYMBOL_GPL(sec_vib_notifier_register);

int sec_vib_notifier_unregister(struct notifier_block *noti_block)
{
	int ret = 0;

	pr_info("%s\n", __func__);

	if (!noti_block)
		return -EINVAL;

	ret = blocking_notifier_chain_unregister(&sec_vib_nb_head, noti_block);
	if (ret < 0)
		pr_err("%s: failed(%d)\n", __func__, ret);

	return ret;
}
EXPORT_SYMBOL_GPL(sec_vib_notifier_unregister);

static int sec_vib_notifier_notify(int en, struct sec_vibrator_drvdata *ddata)
{
	int ret = 0;

	if (!ddata) {
		pr_err("%s : ddata is NULL\n", __func__);
		return -ENODATA;
	}

	vib_notifier.index = ddata->index;
	vib_notifier.timeout = ddata->timeout;

	pr_info("%s: %s, idx: %d timeout: %d\n", __func__, en ? "ON" : "OFF",
		vib_notifier.index, vib_notifier.timeout);

	ret = blocking_notifier_call_chain(&sec_vib_nb_head, en, &vib_notifier);

	switch (ret) {
	case NOTIFY_DONE:
	case NOTIFY_OK:
		pr_info("%s done(0x%x)\n", __func__, ret);
		break;
	default:
		pr_info("%s failed(0x%x)\n", __func__, ret);
		break;
	}

	return ret;
}
#endif /* if IS_ENABLED(CONFIG_SEC_VIB_NOTIFIER) */

#if IS_ENABLED(CONFIG_BATTERY_SAMSUNG)
static int sec_vibrator_check_temp(struct sec_vibrator_drvdata *ddata)
{
	int ret = 0;
	union power_supply_propval value = {0, };

	if (!ddata) {
		pr_err("%s : ddata is NULL\n", __func__);
		return -ENODATA;
	}

	if (!ddata->vib_ops->set_tuning_with_temp)
		return -ENOSYS;

	if (!ddata->temp_cache_valid ||
	    time_is_before_eq_jiffies(ddata->next_temp_check_jiffies)) {
		psy_do_property("battery", get, POWER_SUPPLY_PROP_TEMP, value);
		ddata->cached_temp = value.intval;
		ddata->next_temp_check_jiffies =
			jiffies + msecs_to_jiffies(VIB_TEMP_CACHE_TIMEOUT_MS);
		ddata->temp_cache_valid = true;
	} else {
		value.intval = ddata->cached_temp;
	}

	ret = ddata->vib_ops->set_tuning_with_temp(ddata->dev, value.intval);

	if (ret)
		pr_err("%s error(%d)\n", __func__, ret);

	return ret;
}
#endif
__visible_for_testing int sec_vibrator_set_enable(struct sec_vibrator_drvdata *ddata, bool en)
{
	int ret = 0;

	if (!ddata) {
		pr_err("%s : ddata is NULL\n", __func__);
		return -ENODATA;
	}

	if (!ddata->vib_ops->enable)
		return -ENOSYS;

	ret = ddata->vib_ops->enable(ddata->dev, en);
	if (ret)
		pr_err("%s error(%d)\n", __func__, ret);

#if IS_ENABLED(CONFIG_SEC_VIB_NOTIFIER)
	sec_vib_notifier_notify(en, ddata);
#endif
	return ret;
}

__visible_for_testing int sec_vibrator_set_intensity(struct sec_vibrator_drvdata *ddata, int intensity)
{
	int ret = 0;

	if (!ddata) {
		pr_err("%s : ddata is NULL\n", __func__);
		return -ENODATA;
	}

	if (!ddata->vib_ops->set_intensity)
		return -ENOSYS;

	if ((intensity < -(MAX_INTENSITY)) || (intensity > MAX_INTENSITY)) {
		pr_err("%s out of range(%d)\n", __func__, intensity);
		return -EINVAL;
	}

	ret = ddata->vib_ops->set_intensity(ddata->dev, intensity);

	if (ret)
		pr_err("%s error(%d)\n", __func__, ret);

	return ret;
}

__visible_for_testing int sec_vibrator_set_frequency(struct sec_vibrator_drvdata *ddata, int frequency)
{
	int ret = 0;

	if (!ddata) {
		pr_err("%s : ddata is NULL\n", __func__);
		return -ENODATA;
	}

	if (!ddata->vib_ops->set_frequency)
		return -ENOSYS;

	if ((frequency < FREQ_ALERT) ||
	    ((frequency >= FREQ_MAX) && (frequency < HAPTIC_ENGINE_FREQ_MIN)) ||
	    (frequency > HAPTIC_ENGINE_FREQ_MAX)) {
		pr_err("%s out of range(%d)\n", __func__, frequency);
		return -EINVAL;
	}

	ret = ddata->vib_ops->set_frequency(ddata->dev, frequency);

	if (ret)
		pr_err("%s error(%d)\n", __func__, ret);

	return ret;
}

__visible_for_testing int sec_vibrator_set_overdrive(struct sec_vibrator_drvdata *ddata, bool en)
{
	int ret = 0;

	if (!ddata) {
		pr_err("%s : ddata is NULL\n", __func__);
		return -ENODATA;
	}

	if (!ddata->vib_ops->set_overdrive)
		return -ENOSYS;

	ddata->overdrive = en;
	ret = ddata->vib_ops->set_overdrive(ddata->dev, en);
	if (ret)
		pr_err("%s error(%d)\n", __func__, ret);

	return ret;
}

static bool sec_vibrator_use_short_overdrive(struct sec_vibrator_drvdata *ddata)
{
	if (!ddata || ddata->f_packet_en || !ddata->vib_ops->set_overdrive)
		return false;

	return ddata->timeout > 0 &&
		ddata->timeout <= VIB_SHORT_OVERDRIVE_TIMEOUT_MS &&
		ddata->intensity > 0;
}

static void sec_vibrator_haptic_enable(struct sec_vibrator_drvdata *ddata)
{
	if (!ddata) {
		pr_err("%s : ddata is NULL\n", __func__);
		return;
	}

#if IS_ENABLED(CONFIG_BATTERY_SAMSUNG)
	sec_vibrator_check_temp(ddata);
#endif
	sec_vibrator_set_overdrive(ddata, sec_vibrator_use_short_overdrive(ddata));
	sec_vibrator_set_frequency(ddata, ddata->frequency);
	sec_vibrator_set_intensity(ddata, ddata->intensity);
	sec_vibrator_set_enable(ddata, true);
}

static void sec_vibrator_haptic_disable(struct sec_vibrator_drvdata *ddata)
{
	if (!ddata) {
		pr_err("%s : ddata is NULL\n", __func__);
		return;
	}

	/* clear common variables */
	ddata->index = 0;

	/* clear haptic engine variables */
	ddata->f_packet_en = false;
	ddata->packet_cnt = 0;
	ddata->packet_size = 0;

	sec_vibrator_set_enable(ddata, false);
	sec_vibrator_set_overdrive(ddata, false);
	sec_vibrator_set_frequency(ddata, FREQ_ALERT);
	sec_vibrator_set_intensity(ddata, 0);
}

static void sec_vibrator_engine_run_packet(struct sec_vibrator_drvdata *ddata, struct vib_packet packet)
{
	int frequency = packet.freq;
	int intensity = packet.intensity;
	int overdrive = packet.overdrive;

	if (!ddata) {
		pr_err("%s : ddata is NULL\n", __func__);
		return;
	}

	if (!ddata->f_packet_en) {
		pr_err("haptic packet is empty\n");
		return;
	}

	sec_vibrator_set_overdrive(ddata, overdrive);
	sec_vibrator_set_frequency(ddata, frequency);
	if (intensity) {
		sec_vibrator_set_intensity(ddata, intensity);
		if (!ddata->packet_running) {
			pr_info("[haptic engine] motor run\n");
			sec_vibrator_set_enable(ddata, true);
		}
		ddata->packet_running = true;
	} else {
		if (ddata->packet_running) {
			sec_vibrator_set_enable(ddata, false);
		}
		ddata->packet_running = false;
		sec_vibrator_set_intensity(ddata, intensity);
	}
}

static void timed_output_enable(struct sec_vibrator_drvdata *ddata, unsigned int value)
{
	struct hrtimer *timer = &ddata->timer;
	int ret = 0;

	if (!ddata) {
		pr_err("%s : ddata is NULL\n", __func__);
		return;
	}

	ret = hrtimer_cancel(timer);
	kthread_cancel_work_sync(&ddata->kwork);

	mutex_lock(&ddata->vib_mutex);

	value = min_t(int, value, MAX_TIMEOUT);
	ddata->timeout = value;

	if (value) {
		if (ddata->f_packet_en) {
			ddata->packet_running = false;
			ddata->timeout = ddata->vib_pac[0].time;
			sec_vibrator_engine_run_packet(ddata, ddata->vib_pac[0]);
		} else {
			sec_vibrator_haptic_enable(ddata);
		}

		if (!ddata->index)
			hrtimer_start(timer, ns_to_ktime((u64)ddata->timeout * NSEC_PER_MSEC), HRTIMER_MODE_REL);
	} else {
		sec_vibrator_haptic_disable(ddata);
	}

	mutex_unlock(&ddata->vib_mutex);
}

static enum hrtimer_restart haptic_timer_func(struct hrtimer *timer)
{
	struct sec_vibrator_drvdata *ddata;

	if (!timer) {
		pr_err("%s : timer is NULL\n", __func__);
		return -ENODATA;
	}

	ddata = container_of(timer, struct sec_vibrator_drvdata, timer);

	if (!ddata) {
		pr_err("%s : ddata is NULL\n", __func__);
		return -ENODATA;
	}

	kthread_queue_work(&ddata->kworker, &ddata->kwork);
	return HRTIMER_NORESTART;
}

static void sec_vibrator_work(struct kthread_work *work)
{
	struct sec_vibrator_drvdata *ddata;
	struct hrtimer *timer;

	if (!work) {
		pr_err("%s : work is NULL\n", __func__);
		return;
	}

	ddata = container_of(work, struct sec_vibrator_drvdata, kwork);

	if (!ddata) {
		pr_err("%s : ddata is NULL\n", __func__);
		return;
	}

	timer = &ddata->timer;

	if (!timer) {
		pr_err("%s : timer is NULL\n", __func__);
		return;
	}

	mutex_lock(&ddata->vib_mutex);

	if (ddata->f_packet_en) {
		ddata->packet_cnt++;
		if (ddata->packet_cnt < ddata->packet_size) {
			ddata->timeout = ddata->vib_pac[ddata->packet_cnt].time;
			sec_vibrator_engine_run_packet(ddata, ddata->vib_pac[ddata->packet_cnt]);
			hrtimer_start(timer, ns_to_ktime((u64)ddata->timeout * NSEC_PER_MSEC), HRTIMER_MODE_REL);
			goto unlock_without_vib_off;
		} else {
			ddata->f_packet_en = false;
			ddata->packet_cnt = 0;
			ddata->packet_size = 0;
		}
	}

	sec_vibrator_haptic_disable(ddata);

unlock_without_vib_off:
	mutex_unlock(&ddata->vib_mutex);
}

__visible_for_testing inline bool is_valid_params(struct device *dev, struct device_attribute *attr,
	const char *buf, struct sec_vibrator_drvdata *ddata)
{
	if (!dev) {
		pr_err("%s : dev is NULL\n", __func__);
		return false;
	}
	if (!attr) {
		pr_err("%s : attr is NULL\n", __func__);
		return false;
	}
	if (!buf) {
		pr_err("%s : buf is NULL\n", __func__);
		return false;
	}
	if (!ddata) {
		pr_err("%s : ddata is NULL\n", __func__);
		return false;
	}
	return true;
}

__visible_for_testing ssize_t intensity_store(struct device *dev, struct device_attribute *attr,
	const char *buf, size_t count)
{
	struct sec_vibrator_drvdata *ddata = g_ddata;
	int intensity = 0, ret = 0;

	if (!is_valid_params(dev, attr, buf, ddata))
		return -ENODATA;

	ret = kstrtoint(buf, 0, &intensity);
	if (ret) {
		pr_err("%s : fail to get intensity\n", __func__);
		return -EINVAL;
	}

	pr_info("%s %d\n", __func__, intensity);

	if ((intensity < 0) || (intensity > MAX_INTENSITY)) {
		pr_err("[VIB]: %s out of range\n", __func__);
		return -EINVAL;
	}

	ddata->intensity = intensity;

	return count;
}

__visible_for_testing ssize_t intensity_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct sec_vibrator_drvdata *ddata = g_ddata;

	if (!is_valid_params(dev, attr, buf, ddata))
		return -ENODATA;
	return snprintf(buf, VIB_BUFSIZE, "intensity: %u\n", ddata->intensity);
}

__visible_for_testing ssize_t multi_freq_store(struct device *dev, struct device_attribute *attr,
	const char *buf, size_t count)
{
	struct sec_vibrator_drvdata *ddata = g_ddata;
	int num, ret;

	if (!is_valid_params(dev, attr, buf, ddata))
		return -ENODATA;

	ret = kstrtoint(buf, 0, &num);
	if (ret) {
		pr_err("fail to get frequency\n");
		return -EINVAL;
	}

	pr_info("%s %d\n", __func__, num);

	ddata->frequency = num;

	return count;
}

__visible_for_testing ssize_t multi_freq_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct sec_vibrator_drvdata *ddata = g_ddata;

	if (!is_valid_params(dev, attr, buf, ddata))
		return -ENODATA;
	return snprintf(buf, VIB_BUFSIZE, "frequency: %d\n", ddata->frequency);
}

// TODO: need to update
__visible_for_testing ssize_t haptic_engine_store(struct device *dev, struct device_attribute *attr,
	const char *buf, size_t count)
{
	struct sec_vibrator_drvdata *ddata = g_ddata;
	int index = 0, _data = 0, tmp = 0;

	if (!is_valid_params(dev, attr, buf, ddata))
		return -ENODATA;

	if (sscanf(buf, "%6d", &_data) != 1)
		return count;

	if (_data > PACKET_MAX_SIZE * VIB_PACKET_MAX) {
		pr_info("%s, [%d] packet size over\n", __func__, _data);
		return count;
	}
	ddata->packet_size = _data / VIB_PACKET_MAX;
	ddata->packet_cnt = 0;
	ddata->f_packet_en = true;
	buf = strstr(buf, " ");

	for (index = 0; index < ddata->packet_size; index++) {
		for (tmp = 0; tmp < VIB_PACKET_MAX; tmp++) {
			if (buf == NULL) {
				pr_err("%s, buf is NULL, Please check packet data again\n", __func__);
				ddata->f_packet_en = false;
				return count;
			}

			if (sscanf(buf++, "%6d", &_data) != 1) {
				pr_err("%s, packet data error, Please check packet data again\n", __func__);
				ddata->f_packet_en = false;
				return count;
			}

			switch (tmp) {
			case VIB_PACKET_TIME:
				ddata->vib_pac[index].time = _data;
				break;
			case VIB_PACKET_INTENSITY:
				ddata->vib_pac[index].intensity = _data;
				break;
			case VIB_PACKET_FREQUENCY:
				ddata->vib_pac[index].freq = _data;
				break;
			case VIB_PACKET_OVERDRIVE:
				ddata->vib_pac[index].overdrive = _data;
				break;
			}
			buf = strstr(buf, " ");
		}
	}

	return count;
}

__visible_for_testing ssize_t haptic_engine_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct sec_vibrator_drvdata *ddata = g_ddata;
	int index = 0;
	size_t size = 0;

	if (!is_valid_params(dev, attr, buf, ddata))
		return -ENODATA;

	for (index = 0; index < ddata->packet_size && ddata->f_packet_en &&
	     ((4 * VIB_BUFSIZE + size) < PAGE_SIZE); index++) {
		size += snprintf(&buf[size], VIB_BUFSIZE, "%u,", ddata->vib_pac[index].time);
		size += snprintf(&buf[size], VIB_BUFSIZE, "%u,", ddata->vib_pac[index].intensity);
		size += snprintf(&buf[size], VIB_BUFSIZE, "%u,", ddata->vib_pac[index].freq);
		size += snprintf(&buf[size], VIB_BUFSIZE, "%u,", ddata->vib_pac[index].overdrive);
	}

	return size;
}

__visible_for_testing ssize_t cp_trigger_index_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct sec_vibrator_drvdata *ddata = g_ddata;
	int ret = 0;

	if (!is_valid_params(dev, attr, buf, ddata))
		return -ENODATA;

	if (!ddata->vib_ops->get_cp_trigger_index)
		return -ENOSYS;

	ret = ddata->vib_ops->get_cp_trigger_index(ddata->dev, buf);

	return ret;
}

__visible_for_testing ssize_t cp_trigger_index_store(struct device *dev, struct device_attribute *attr,
	const char *buf, size_t count)
{
	struct sec_vibrator_drvdata *ddata = g_ddata;
	int ret = 0;
	unsigned int index;

	if (!is_valid_params(dev, attr, buf, ddata))
		return -ENODATA;

	if (!ddata->vib_ops->set_cp_trigger_index)
		return -ENOSYS;

	ret = kstrtou32(buf, 10, &index);
	if (ret)
		return -EINVAL;

	ddata->index = index;

	ret = ddata->vib_ops->set_cp_trigger_index(ddata->dev, buf);
	if (ret < 0)
		pr_err("%s error(%d)\n", __func__, ret);

	return count;
}

__visible_for_testing ssize_t cp_trigger_queue_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct sec_vibrator_drvdata *ddata = g_ddata;
	int ret = 0;

	if (!is_valid_params(dev, attr, buf, ddata))
		return -ENODATA;

	if (!ddata->vib_ops->get_cp_trigger_queue)
		return -ENOSYS;

	ret = ddata->vib_ops->get_cp_trigger_queue(ddata->dev, buf);
	if (ret < 0)
		pr_err("%s error(%d)\n", __func__, ret);

	return ret;
}

__visible_for_testing ssize_t cp_trigger_queue_store(struct device *dev, struct device_attribute *attr,
	const char *buf, size_t count)
{
	struct sec_vibrator_drvdata *ddata = g_ddata;
	int ret = 0;

	if (!is_valid_params(dev, attr, buf, ddata))
		return -ENODATA;

	if (!ddata->vib_ops->set_cp_trigger_queue)
		return -ENOSYS;

	ret = ddata->vib_ops->set_cp_trigger_queue(ddata->dev, buf);
	if (ret < 0)
		pr_err("%s error(%d)\n", __func__, ret);

	return count;
}

__visible_for_testing ssize_t pwle_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct sec_vibrator_drvdata *ddata = g_ddata;
	int ret = 0;

	if (!is_valid_params(dev, attr, buf, ddata))
		return -ENODATA;

	if (!ddata->vib_ops->get_pwle)
		return -ENOSYS;

	ret = ddata->vib_ops->get_pwle(ddata->dev, buf);
	if (ret < 0)
		pr_err("%s error(%d)\n", __func__, ret);

	return ret;
}

__visible_for_testing ssize_t pwle_store(struct device *dev, struct device_attribute *attr,
	const char *buf, size_t count)
{
	struct sec_vibrator_drvdata *ddata = g_ddata;
	int ret = 0;

	if (!is_valid_params(dev, attr, buf, ddata))
		return -ENODATA;

	if (!ddata->vib_ops->set_pwle)
		return -ENOSYS;

	ret = ddata->vib_ops->set_pwle(ddata->dev, buf);
	if (ret < 0)
		pr_err("%s error(%d)\n", __func__, ret);

	return count;
}

__visible_for_testing ssize_t virtual_composite_indexes_show(struct device *dev, struct device_attribute *attr,
	char *buf)
{
	struct sec_vibrator_drvdata *ddata = g_ddata;
	int ret = 0;

	if (!is_valid_params(dev, attr, buf, ddata))
		return -ENODATA;

	if (!ddata->vib_ops->get_virtual_composite_indexes)
		return -ENOSYS;

	ret = ddata->vib_ops->get_virtual_composite_indexes(ddata->dev, buf);
	if (ret < 0)
		pr_err("%s error(%d)\n", __func__, ret);

	return ret;
}

__visible_for_testing ssize_t virtual_pwle_indexes_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct sec_vibrator_drvdata *ddata = g_ddata;
	int ret = 0;

	if (!is_valid_params(dev, attr, buf, ddata))
		return -ENODATA;

	if (!ddata->vib_ops->get_virtual_pwle_indexes)
		return -ENOSYS;

	ret = ddata->vib_ops->get_virtual_pwle_indexes(ddata->dev, buf);
	if (ret < 0)
		pr_err("%s error(%d)\n", __func__, ret);

	return ret;
}

__visible_for_testing ssize_t enable_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct sec_vibrator_drvdata *ddata = g_ddata;
	struct hrtimer *timer = &ddata->timer;
	int remaining = 0;

	if (!is_valid_params(dev, attr, buf, ddata))
		return -ENODATA;

	if (hrtimer_active(timer)) {
		ktime_t remain = hrtimer_get_remaining(timer);
		struct timespec64 t = ns_to_timespec64(remain);

		remaining = t.tv_sec * 1000 + t.tv_nsec / 1000;
	}
	return sprintf(buf, "%d\n", remaining);
}

__visible_for_testing ssize_t enable_store(struct device *dev, struct device_attribute *attr,
	const char *buf, size_t size)
{
	struct sec_vibrator_drvdata *ddata = g_ddata;
	int value;
	int ret;

	if (!is_valid_params(dev, attr, buf, ddata))
		return -ENODATA;

	ret = kstrtoint(buf, 0, &value);
	if (ret != 0)
		return -EINVAL;

	timed_output_enable(ddata, value);
	return size;
}

__visible_for_testing ssize_t motor_type_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct sec_vibrator_drvdata *ddata = g_ddata;
	int ret = 0;

	if (!is_valid_params(dev, attr, buf, ddata))
		return -ENODATA;

	if (!ddata->vib_ops->get_motor_type)
		return snprintf(buf, VIB_BUFSIZE, "NONE\n");

	ret = ddata->vib_ops->get_motor_type(ddata->dev, buf);

	return ret;
}

__visible_for_testing ssize_t use_sep_index_store(struct device *dev, struct device_attribute *attr,
	const char *buf, size_t size)
{
	struct sec_vibrator_drvdata *ddata = g_ddata;
	int ret = 0;
	bool use_sep_index;

	if (!is_valid_params(dev, attr, buf, ddata))
		return -ENODATA;
	
	ret = kstrtobool(buf, &use_sep_index);
	if (ret < 0) {
		pr_err("%s kstrtobool error : %d\n", __func__, ret);
		goto err;
	}
	
	pr_info("%s use_sep_index:%d\n", __func__, use_sep_index);
	
	if