/**
 * @file config_storage.h
 * @brief Persistance de la configuration système sur flash externe
 */

#ifndef CONFIG_STORAGE_H
#define CONFIG_STORAGE_H

#include <stdbool.h>

bool loadLowPowerMode(bool defaultVal = true);
bool saveLowPowerMode(bool value);

#endif // CONFIG_STORAGE_H