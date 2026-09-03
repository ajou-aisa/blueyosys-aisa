#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <cassert>
#include <cmath>

#include <queue>

#include "ttyifc.h"

void rms_norm(float *input, float *output, size_t rows, size_t cols, float eps)
{
	assert(input);
	assert(output);
	assert(rows > 0);
	assert(cols > 0);
	assert(eps > 0.0f);

	for (size_t row = 0; row < rows; ++row)
	{
		const float *x = input + row * cols;
		float *y = output + row * cols;

		double sum_sq = 0.0f;

		for (size_t i = 0; i < cols; ++i) 
			sum_sq += static_cast<double>(x[i]) * x[i];
		
		const float mean_sq = static_cast<float>(sum_sq / cols);
		const float inv_rms = 1.0f / std::sqrt(mean_sq+eps);

		for (size_t i = 0; i < cols; ++i) 
			y[i] = x[i] * inv_rms;
	}
}

void *swmain(void *param)
{
	(void)param;

	float matrix_a[4][4];
	float matrix_c[4][4];
	float matrix_c_golden[4][4] = {0};

	srand(time(NULL));
	for (int i = 0; i < 4; i++)
	{
		for (int j = 0; j < 4; j++)
		{
			// matrix_a[i][j] = 2*i+j;
			matrix_a[i][j] = ((rand() % 128) * 1.0 - 64) / 32;
			for (int k = 0; k < 4; k++)
			{
				float *v = &(matrix_a[i][j]);
				uart_send(((uint8_t *)v)[k]);
			}
		}
	}

	rms_norm(matrix_a[0], matrix_c_golden[0], 4, 4, 1e-5);

	for (int i = 0; i < 4; ++i)
	{
		for (int j = 0; j < 4; ++j)
		{
			uint8_t *value = reinterpret_cast<uint8_t *>(&matrix_c[i][j]);
			for (int byte = 0; byte < 4; ++byte)
			{
				uint32_t received = uart_recv();
				while (received > 0xff)
					received = uart_recv();
				value[byte] = static_cast<uint8_t>(received);
			}
		}
	}

	printf( "Results from accelerator:\n" );
	for ( int i = 0; i < 4; i++ ) {
		for ( int j = 0; j < 4; j++ ) {
			printf( "%2.02f ", matrix_c[i][j] );
		}
		printf("\n");
	}
	printf("\n");

	printf( "Results golden:\n" );
	for ( int i = 0; i < 4; i++ ) {
		for ( int j = 0; j < 4; j++ ) {
			printf( "%2.02f ", matrix_c_golden[i][j] );
		}
		printf("\n");
	}
	printf("\n");

	printf( "Finished execution!\n" );
	fflush(stdout);
	exit(0);
}

int
main() {
	int ret = open_tty("/dev/ttyUSB0");
	if ( ret ) return ret;

	swmain(NULL);
}
