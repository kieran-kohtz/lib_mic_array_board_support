// Copyright (c) 2016-2017, XMOS Ltd, All rights reserved
#include <xscope.h>
#include <platform.h>
#include <xs1.h>
#include <xs2_su_registers.h>
#include <string.h>
#include <xclib.h>
#include <stdint.h>
#include "stdio.h"
#include <stdlib.h>
#include <math.h>

#include "mic_array.h"
#include "mic_array_board_support.h"

#define LOGGING 1
#define ENABLE_PRECISION_MAXIMISATION 1

//If the decimation factor is changed the the coefs array of decimator_config must also be changed.
#define DECIMATION_FACTOR   6   //Corresponds to a 48kHz output sample rate
#define DECIMATOR_COUNT     2   //8 channels requires 2 decimators
#define FRAME_BUFFER_COUNT  3   //The minimum of 2 will suffice for this example

#define FRAME_LENGTH (1<<MIC_ARRAY_MAX_FRAME_SIZE_LOG2)
#define FFT_SINE_LUT dsp_sine_128
#define FFT_CHANNELS ((COUNT+1)/2)

on tile[0]: out port p_pdm_clk              = XS1_PORT_1E;
on tile[0]: in buffered port:32 p_pdm_mics  = XS1_PORT_8B;
on tile[0]: in port p_mclk                  = XS1_PORT_1F;
on tile[0]: clock pdmclk                    = XS1_CLKBLK_2;

int data[8][THIRD_STAGE_COEFS_PER_STAGE*DECIMATION_FACTOR];

int your_favourite_window_function(unsigned i, unsigned window_length){
    return((int)((double)INT_MAX*sqrt(0.5*(1.0 - cos(2.0 * 3.14159265359*(double)i / (double)(window_length-2))))));
}

//This is here until lib_dsp is updated.
void dsp_bfp_shl2( dsp_complex_t pts[], const uint32_t N,
                   const int32_t shift_re, const int32_t shift_im );

void test(streaming chanend c_ds_output[DECIMATOR_COUNT]) {
    unsafe{
        unsigned buffer;
        memset(data, 0, sizeof(data));

        mic_array_frame_fft_preprocessed audio[FRAME_BUFFER_COUNT];

        int window[FRAME_LENGTH/2];
        for(unsigned i=0;i<FRAME_LENGTH/2;i++)
             window[i] = your_favourite_window_function(i, FRAME_LENGTH);

        mic_array_decimator_conf_common_t dcc = {
                MIC_ARRAY_MAX_FRAME_SIZE_LOG2,
                1, //dc removal
                1, //bit reversed indexing
                window,
                DECIMATION_FACTOR,
                g_third_stage_div_6_fir,
                0,
                FIR_COMPENSATOR_DIV_6,
                DECIMATOR_HALF_FRAME_OVERLAP,
                FRAME_BUFFER_COUNT};
        mic_array_decimator_config_t dc[2] = {
          {&dcc, data[0], {INT_MAX, INT_MAX, INT_MAX, INT_MAX}, 4},
          {&dcc, data[4], {INT_MAX, INT_MAX, INT_MAX, INT_MAX}, 4}
        };

        mic_array_decimator_configure(c_ds_output, DECIMATOR_COUNT, dc);

        mic_array_init_frequency_domain_frame(c_ds_output, DECIMATOR_COUNT, buffer, audio, dc);

        for(unsigned i=0;i<16;i++)
            mic_array_get_next_frequency_domain_frame(c_ds_output, DECIMATOR_COUNT, buffer, audio, dc);

#define R 10
#define REPS (1<<R)

        int64_t subband_rms_power[COUNT][FRAME_LENGTH/2];
        memset(subband_rms_power, 0, sizeof(subband_rms_power));

        for(unsigned r=0;r<REPS;r++){

            mic_array_frame_fft_preprocessed *  current =
                    mic_array_get_next_frequency_domain_frame(c_ds_output, DECIMATOR_COUNT, buffer, audio, dc);

            int ch_headroom[COUNT] = {0};
#if ENABLE_PRECISION_MAXIMISATION
            for(unsigned channel_pairs=0;channel_pairs<(COUNT+1)/2;channel_pairs++){
                unsigned dec = (2*channel_pairs)/4;
                unsigned dec_ch = (2*channel_pairs) - dec*4;
                int im=0, re = clz(current->metadata[dec].sig_bits[dec_ch])-2;
                ch_headroom[2*channel_pairs] = re;

                if(2*channel_pairs+1 < COUNT){
                    im = clz(current->metadata[dec].sig_bits[dec_ch+1])-2;
                    ch_headroom[2*channel_pairs+1] = im;
                }
                dsp_bfp_shl2(current->data[channel_pairs], FRAME_LENGTH, re, im);
            }
#endif
            for(unsigned i=0;i<FFT_CHANNELS;i++){
                dsp_fft_forward(current->data[i], FRAME_LENGTH, FFT_SINE_LUT);
                dsp_fft_split_spectrum(current->data[i], FRAME_LENGTH);
            }

            mic_array_frame_frequency_domain * fd_frame = (mic_array_frame_frequency_domain*)current;

            for(unsigned ch=0;ch<COUNT;ch++){
                for (unsigned band=0;band < FRAME_LENGTH/2;band++){
                    int64_t power = (int64_t)fd_frame->data[ch][band].re *  (int64_t)fd_frame->data[ch][band].re +
                            (int64_t)fd_frame->data[ch][band].im * (int64_t)fd_frame->data[ch][band].im;
                    power >>= (R + (2*ch_headroom[ch]));
                    subband_rms_power[ch][band] += power;
                }
            }
        }

        //This can be used to restrict the bandwidth
        unsigned lower_bin = 1;//We never care about the DC and the NQ
        unsigned upper_bin = FRAME_LENGTH/2 ;

#if LOGGING
        for (unsigned band=1;band < FRAME_LENGTH/2;band++){
            for(unsigned ch_b=0;ch_b<COUNT;ch_b++){
                int64_t b = subband_rms_power[ch_b][band];
                printf("%.12f ", sqrt((double)b));
            }
            printf("\n");
        }
#endif

        double bin_count = (double)(upper_bin-lower_bin);
        double x_bar[COUNT] = {0};
        double xx_bar[COUNT] = {0};
        double xy_bar[COUNT][COUNT];
        memset(xy_bar, 0, sizeof(xy_bar));

        for (unsigned band=lower_bin;band < upper_bin;band++){

            double m[COUNT];
            for(unsigned ch=0;ch<COUNT;ch++){
                int64_t b = subband_rms_power[ch][band];
                m[ch] = sqrt((double)b);
                x_bar[ch] += m[ch];
                xx_bar[ch] += (m[ch]*m[ch]);
            }
            for(unsigned ch_a=0;ch_a<COUNT;ch_a++){
                for(unsigned ch_b=ch_a + 1;ch_b<COUNT;ch_b++){
                    xy_bar[ch_a][ch_b] += (m[ch_a]*m[ch_b]);
                }
            }
        }
        for(unsigned ch_a=0;ch_a<COUNT;ch_a++){
            x_bar[ch_a] /= bin_count;
            xx_bar[ch_a] /= bin_count;
            for(unsigned ch_b=ch_a + 1;ch_b<COUNT;ch_b++){
                xy_bar[ch_a][ch_b] /= bin_count;
            }
        }

        double sum_xx[COUNT] = {0};
        double sum_xy[COUNT][COUNT];
        memset(sum_xy, 0, sizeof(sum_xy));

        for (unsigned band=lower_bin;band < upper_bin;band++){

            double m[COUNT];
            for(unsigned ch=0;ch<COUNT;ch++){
                int64_t b = subband_rms_power[ch][band];
                m[ch] = sqrt((double)b);
            }

            for(unsigned ch_a=0;ch_a<COUNT;ch_a++){
                double a = m[ch_a];
                sum_xx[ch_a] += ((a-x_bar[ch_a])*(a-x_bar[ch_a]));

                for(unsigned ch_b=ch_a + 1;ch_b<COUNT;ch_b++){
                    double b = m[ch_b];
                    sum_xy[ch_a][ch_b] += ((a-x_bar[ch_a])*(b-x_bar[ch_b]));
                }
            }
        }

#define DB_BIG 1000.0

        double max_db_diff = -DB_BIG;
        double min_r = DB_BIG, max_r = -DB_BIG;

        for(unsigned ch_a=0;ch_a<COUNT;ch_a++){
            for(unsigned ch_b=ch_a + 1;ch_b<COUNT;ch_b++){
                double beta = sum_xy[ch_a][ch_b] / sum_xx[ch_a];
                double beta_db;
                if(beta > 0.0){
                    beta_db = 20*log10(beta);
                } else {
                    beta_db = -DB_BIG;
                }
                max_db_diff = fmax(max_db_diff, fabs(beta_db));
#if LOGGING
                printf("beta:%fdb = %f\n", beta_db, beta);
#endif
            }
        }

        for(unsigned ch_a=0;ch_a<COUNT;ch_a++){
            for(unsigned ch_b=ch_a + 1;ch_b<COUNT;ch_b++){
                double r = (xy_bar[ch_a][ch_b] - x_bar[ch_a]*x_bar[ch_b]) /
                        sqrt((xx_bar[ch_a] - x_bar[ch_a]*x_bar[ch_a]) *
                                (xx_bar[ch_b] - x_bar[ch_b]*x_bar[ch_b]));
                max_r = fmax(max_r, r);
                min_r = fmin(min_r, r);
#if LOGGING
                printf("r: %f\n", r);
#endif
            }
        }

        double diff = max_db_diff;
        if(diff < 12.0){
            printf("Pass: %fdb spread\n", diff);
            _Exit(0);
        } else{
            printf("Fail: %fdb spread\n", diff);
            _Exit(1);
        }
    }
}

port p_rst_shared                   = on tile[1]: XS1_PORT_4F; // Bit 0: DAC_RST_N, Bit 1: ETH_RST_N
port p_i2c                          = on tile[1]: XS1_PORT_4E; // Bit 0: SCLK, Bit 1: SDA
int main() {
    chan c_sync;
    i2c_master_if i_i2c[1];
    par {
        on tile[1]: i2c_master_single_port(i_i2c, 1, p_i2c, 100, 0, 1, 0);
        on tile[1]: {
            p_rst_shared <: 0x00;
            mabs_init_pll(i_i2c[0], SMART_MIC_BASE);
            delay_seconds(5);
            c_sync <: 1;
        }

        on tile[0]:{
            c_sync :> int;

            stop_clock(pdmclk);
            configure_clock_src_divide(pdmclk, p_mclk, 4);
            configure_port_clock_output(p_pdm_clk, pdmclk);
            configure_in_port(p_pdm_mics, pdmclk);
            start_clock(pdmclk);

            streaming chan c_4x_pdm_mic[DECIMATOR_COUNT];
            streaming chan c_ds_output[DECIMATOR_COUNT];

            par {
                mic_array_pdm_rx(p_pdm_mics, c_4x_pdm_mic[0], c_4x_pdm_mic[1]);
                mic_array_decimate_to_pcm_4ch(c_4x_pdm_mic[0], c_ds_output[0], MIC_ARRAY_NO_INTERNAL_CHANS);
                mic_array_decimate_to_pcm_4ch(c_4x_pdm_mic[1], c_ds_output[1], MIC_ARRAY_NO_INTERNAL_CHANS);
                test(c_ds_output);
            }

        }

    }
    return 0;
}
